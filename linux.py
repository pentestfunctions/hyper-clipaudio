#!/usr/bin/env python3
import socket
import subprocess
import threading
import time
import base64
import os
import json
import pyaudio
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path
import sys
import traceback
import zlib
from typing import Dict, Set, Optional
from datetime import datetime

# Configuration
CHUNK = 1024
FORMAT = pyaudio.paInt16
CHANNELS = 2
RATE = 44100
HOST = '0.0.0.0'  # Listen on all interfaces
CLIPBOARD_PORT = 5000
AUDIO_PORT = 5001
MAX_CHUNK_SIZE = 1024 * 1024  # 1MB chunks for large files
MAX_CLIENTS = 50
SOCKET_TIMEOUT = 30
KEEP_ALIVE_INTERVAL = 1.0

class ServerStats:
    def __init__(self):
        self.start_time = datetime.now()
        self.total_bytes_transferred = 0
        self.total_files_transferred = 0
        self.peak_connected_clients = 0
        self.current_connected_clients = 0
        self._lock = threading.Lock()

    def update_bytes(self, bytes_count: int):
        with self._lock:
            self.total_bytes_transferred += bytes_count

    def update_files(self, count: int = 1):
        with self._lock:
            self.total_files_transferred += count

    def update_clients(self, current_count: int):
        with self._lock:
            self.current_connected_clients = current_count
            self.peak_connected_clients = max(self.peak_connected_clients, current_count)

    def get_stats(self) -> dict:
        with self._lock:
            return {
                'uptime': str(datetime.now() - self.start_time),
                'total_data_transferred': f"{self.total_bytes_transferred / (1024*1024):.2f} MB",
                'files_transferred': self.total_files_transferred,
                'current_clients': self.current_connected_clients,
                'peak_clients': self.peak_connected_clients
            }

class ClipboardHandler:
    def __init__(self):
        self.last_content = None
        self.clipboard_dir = Path.home() / 'ClipboardSync'
        self.clipboard_dir.mkdir(exist_ok=True)
        self.clients: Set[socket.socket] = set()
        self._lock = threading.Lock()
        
    def add_client(self, client: socket.socket):
        with self._lock:
            self.clients.add(client)
            
    def remove_client(self, client: socket.socket):
        with self._lock:
            if client in self.clients:
                self.clients.remove(client)
                
    def broadcast(self, sender: socket.socket, message: bytes):
        with self._lock:
            dead_clients = set()
            for client in self.clients:
                if client != sender:
                    try:
                        client.sendall(message)
                    except Exception as e:
                        logging.error(f"Error broadcasting to client: {e}")
                        dead_clients.add(client)
            
            # Cleanup dead clients
            for client in dead_clients:
                self.remove_client(client)

    def get_clipboard_content(self) -> Optional[Dict]:
        """Get clipboard content from Linux system"""
        try:
            result = subprocess.run(['xclip', '-selection', 'clipboard', '-o'], 
                                 capture_output=True, text=True)
            if result.returncode == 0 and result.stdout:
                return {
                    'type': 'text',
                    'data': result.stdout
                }
        except Exception as e:
            logging.error(f"Error getting clipboard content: {e}")
        return None

class AudioServer:
    def __init__(self, host='0.0.0.0', port=AUDIO_PORT):
        self.host = host
        self.port = port
        self.p = pyaudio.PyAudio()
        # Open input stream for microphone capture
        self.audio_stream = self.p.open(
            format=FORMAT,
            channels=CHANNELS,
            rate=RATE,
            input=True,
            frames_per_buffer=CHUNK
        )
        self.clients = []
        self.running = True

    def start_server(self):
        # Set up server socket
        server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_socket.bind((self.host, self.port))
        server_socket.listen(5)
        logging.info(f"Audio Server listening on {self.host}:{self.port}")

        # Accept new clients
        accept_thread = threading.Thread(target=self.accept_clients, args=(server_socket,))
        accept_thread.start()

        # Stream audio to clients
        self.stream_audio()

        # Clean up
        self.running = False
        self.audio_stream.stop_stream()
        self.audio_stream.close()
        self.p.terminate()
        server_socket.close()

    def accept_clients(self, server_socket):
        while self.running:
            client_socket, client_address = server_socket.accept()
            logging.info(f"Audio Client {client_address} connected")
            self.clients.append(client_socket)

    def stream_audio(self):
        while self.running:
            try:
                # Capture audio from microphone
                audio_data = self.audio_stream.read(CHUNK, exception_on_overflow=False)
                # Send to each connected client
                for client in self.clients[:]:  # Create a copy of list for safe iteration
                    try:
                        client.sendall(audio_data)
                    except Exception as e:
                        logging.error(f"Error sending audio to client: {e}")
                        self.clients.remove(client)
            except Exception as e:
                logging.error(f"Audio streaming error: {e}")
                break

class UnifiedServer:
    def __init__(self):
        self.running = False
        self.clipboard_handler = ClipboardHandler()
        self.audio_server = AudioServer()
        self.stats = ServerStats()
        self.setup_logging()

    def setup_logging(self):
        log_dir = Path.home() / 'ClipboardSync' / 'logs'
        log_dir.mkdir(exist_ok=True, parents=True)
        
        log_file = log_dir / f"server_{datetime.now().strftime('%Y%m%d')}.log"
        
        # Setup rotating file handler
        handler = RotatingFileHandler(
            log_file,
            maxBytes=5*1024*1024,  # 5MB
            backupCount=5
        )
        
        formatter = logging.Formatter(
            '%(asctime)s - %(levelname)s - [%(threadName)s] %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
        
        handler.setFormatter(formatter)
        
        logger = logging.getLogger()
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        
        # Also log to console
        console_handler = logging.StreamHandler()
        console_handler.setFormatter(formatter)
        logger.addHandler(console_handler)
        
        logging.info("Server logging initialized")

    def handle_clipboard_client(self, client_socket: socket.socket, address: str):
        logging.info(f"New clipboard connection from {address}")
        self.clipboard_handler.add_client(client_socket)
        self.stats.update_clients(len(self.clipboard_handler.clients))
        
        try:
            while self.running:
                try:
                    client_socket.settimeout(0.1)
                    header = b""
                    while b":" not in header:
                        chunk = client_socket.recv(1)
                        if not chunk:
                            raise ConnectionError("Client disconnected")
                        header += chunk
                    
                    size = int(header.decode('utf-8').strip(":"))
                    data = b""
                    remaining = size
                    
                    while remaining > 0:
                        chunk = client_socket.recv(min(remaining, 8192))
                        if not chunk:
                            raise ConnectionError("Connection lost while receiving data")
                        data += chunk
                        remaining -= len(chunk)
                    
                    # Update transfer statistics
                    self.stats.update_bytes(len(data))
                    
                    content = json.loads(data.decode('utf-8'))
                    
                    # Handle keep-alive messages
                    if content.get('type') == 'keep_alive':
                        continue
                    
                    # Handle different message types
                    if content.get('type') == 'file_info':
                        # Start collecting file chunks
                        file_chunks = []
                        file_info = content.copy()
                        original_size = file_info['size']
                        
                        logging.info(f"Starting file transfer: {file_info['name']}, size: {original_size} bytes")
                        
                        # Initialize tracking variables
                        raw_data_size = 0
                        
                        # Receive all chunks for this file
                        while True:
                            chunk_header = b""
                            while b":" not in chunk_header:
                                chunk = client_socket.recv(1)
                                if not chunk:
                                    raise ConnectionError("Client disconnected during chunk transfer")
                                chunk_header += chunk
                            
                            chunk_size = int(chunk_header.decode('utf-8').strip(":"))
                            chunk_data = b""
                            chunk_remaining = chunk_size
                            
                            while chunk_remaining > 0:
                                chunk = client_socket.recv(min(chunk_remaining, 8192))
                                if not chunk:
                                    raise ConnectionError("Connection lost during chunk transfer")
                                chunk_data += chunk
                                chunk_remaining -= len(chunk)
                            
                            chunk_content = json.loads(chunk_data.decode('utf-8'))
                            
                            if chunk_content['type'] != 'file_chunk':
                                break
                                
                            chunk_base64 = chunk_content['chunk']
                            file_chunks.append(chunk_base64)
                            
                            # Track the actual data size before base64 decoding
                            try:
                                # Decode a small portion to check validity
                                test_decode = base64.b64decode(chunk_base64.encode('utf-8'))
                                raw_data_size += len(test_decode)
                            except Exception as e:
                                logging.error(f"Error decoding chunk: {e}")
                                continue
                            
                            if chunk_content.get('final'):
                                try:
                                    # Join all base64 chunks
                                    complete_base64 = ''.join(file_chunks)
                                    
                                    # Decode base64 data
                                    decoded_data = base64.b64decode(complete_base64.encode('utf-8'))
                                    
                                    # Decompress if needed
                                    if file_info.get('compressed', False):
                                        decoded_data = zlib.decompress(decoded_data)
                                    
                                    # Verify final size
                                    if len(decoded_data) != original_size:
                                        logging.warning(f"Size mismatch after decoding/decompressing. Expected: {original_size}, Got: {len(decoded_data)}")
                                    
                                    # Save file
                                    file_path = self.clipboard_handler.clipboard_dir / file_info['name']
                                    with open(file_path, 'wb') as f:
                                        f.write(decoded_data)
                                    
                                    logging.info(f"Successfully saved file: {file_info['name']}")
                                    
                                    # Broadcast to other clients
                                    complete_file = {
                                        'type': 'files',
                                        'files': [{
                                            'name': file_info['name'],
                                            'size': original_size,
                                            'data': complete_base64,
                                            'compressed': file_info.get('compressed', False)
                                        }]
                                    }
                                    
                                    file_data = json.dumps(complete_file)
                                    message = f"{len(file_data)}:{file_data}".encode('utf-8')
                                    self.clipboard_handler.broadcast(client_socket, message)
                                    self.stats.update_files(1)
                                    
                                except Exception as e:
                                    logging.error(f"Error processing final file chunk: {e}")
                                    logging.debug(traceback.format_exc())
                                break
                                
                    elif content.get('type') == 'text':
                        # Handle text content
                        try:
                            # Save to system clipboard
                            text_data = content['data']
                            with subprocess.Popen(['xclip', '-selection', 'clipboard'], stdin=subprocess.PIPE) as proc:
                                proc.stdin.write(text_data.encode('utf-8'))
                                proc.stdin.close()
                                proc.wait()
                            
                            # Broadcast to other clients
                            message = data
                            self.clipboard_handler.broadcast(client_socket, message)
                            logging.info("Text content processed and broadcasted")
                        except Exception as e:
                            logging.error(f"Error processing text content: {e}")
                    
                except socket.timeout:
                    pass
                except Exception as e:
                    logging.error(f"Error handling client data: {e}")
                    logging.debug(f"Error details: {traceback.format_exc()}")
                    raise
                
                time.sleep(0.1)
                
        except Exception as e:
            logging.error(f"Clipboard client error: {e}")
            logging.debug(f"Client error details: {traceback.format_exc()}")
        finally:
            self.clipboard_handler.remove_client(client_socket)
            self.stats.update_clients(len(self.clipboard_handler.clients))
            try:
                client_socket.close()
            except:
                pass
            logging.info(f"Clipboard client disconnected: {address}")

    def get_local_ip(self) -> list:
        """Get all local IP addresses"""
        ips = []
        try:
            interfaces = socket.getaddrinfo(
                host=socket.gethostname(),
                port=None,
                family=socket.AF_INET
            )
            ips = sorted(list(set(ip[4][0] for ip in interfaces if not ip[4][0].startswith('127.'))))
        except Exception as e:
            logging.error(f"Error getting local IPs: {e}")
            ips = ['0.0.0.0']
        return ips

    def log_server_stats(self):
        """Periodically log server statistics"""
        while self.running:
            stats = self.stats.get_stats()
            logging.info("Server Statistics:")
            for key, value in stats.items():
                logging.info(f"  {key}: {value}")
            time.sleep(300)  # Log every 5 minutes

    def start(self):
        self.running = True
        
        # Start stats logging thread
        stats_thread = threading.Thread(
            target=self.log_server_stats,
            name="StatsLogger"
        )
        stats_thread.daemon = True
        stats_thread.start()
        
        # Start audio server
        audio_thread = threading.Thread(
            target=self.audio_server.start_server,  # Using start_server instead of start
            name="AudioServer"
        )
        audio_thread.daemon = True
        audio_thread.start()
        
        # Start clipboard server
        clipboard_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        clipboard_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        clipboard_server.bind((HOST, CLIPBOARD_PORT))
        clipboard_server.listen(MAX_CLIENTS)
        
        local_ips = self.get_local_ip()
        logging.info("Server started on:")
        for ip in local_ips:
            logging.info(f"  {ip} - Clipboard port: {CLIPBOARD_PORT}, Audio port: {AUDIO_PORT}")
        
        try:
            while self.running:
                try:
                    client_socket, address = clipboard_server.accept()
                    if len(self.clipboard_handler.clients) >= MAX_CLIENTS:
                        logging.warning(f"Maximum clients reached, rejecting connection from {address}")
                        client_socket.close()
                        continue
                        
                    thread = threading.Thread(
                        target=self.handle_clipboard_client,
                        args=(client_socket, address),
                        name=f"ClipboardClient-{address}"
                    )
                    thread.daemon = True
                    thread.start()
                except Exception as e:
                    if self.running:
                        logging.error(f"Error accepting clipboard client: {e}")
                        logging.debug(f"Accept error details: {traceback.format_exc()}")
                
                time.sleep(0.1)
                
        except KeyboardInterrupt:
            logging.info("Shutting down server...")
        except Exception as e:
            logging.error(f"Server error: {e}")
            logging.debug(f"Server error details: {traceback.format_exc()}")
        finally:
            self.running = False
            
            # Close all clipboard clients
            for client in list(self.clipboard_handler.clients):
                try:
                    client.close()
                except:
                    pass
            
            # Close clipboard server
            try:
                clipboard_server.close()
            except:
                pass
            
            logging.info("Server shutdown complete")

if __name__ == "__main__":
    server = UnifiedServer()
    server.start()
