#!/usr/bin/env python3
import socket
import json
import base64
import subprocess
import threading
import os
import pyaudio
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path
import time
from datetime import datetime
import traceback

# Configuration
CHUNK = 1024
FORMAT = pyaudio.paInt16
CHANNELS = 2
RATE = 44100
HOST = '0.0.0.0'
CLIPBOARD_PORT = 12345
AUDIO_PORT = 5001
MAX_CLIENTS = 50

class ServerStats:
    def __init__(self):
        self.start_time = datetime.now()
        self.audio_clients = 0
        self.clipboard_clients = 0
        self.peak_audio_clients = 0
        self.peak_clipboard_clients = 0
        self._lock = threading.Lock()

    def update_clients(self, audio_count=None, clipboard_count=None):
        with self._lock:
            if audio_count is not None:
                self.audio_clients = audio_count
                self.peak_audio_clients = max(self.peak_audio_clients, audio_count)
            if clipboard_count is not None:
                self.clipboard_clients = clipboard_count
                self.peak_clipboard_clients = max(self.peak_clipboard_clients, clipboard_count)

    def get_stats(self) -> dict:
        with self._lock:
            return {
                'uptime': str(datetime.now() - self.start_time),
                'current_audio_clients': self.audio_clients,
                'peak_audio_clients': self.peak_audio_clients,
                'current_clipboard_clients': self.clipboard_clients,
                'peak_clipboard_clients': self.peak_clipboard_clients
            }

class AudioServer:
    def __init__(self, stats, host='0.0.0.0', port=AUDIO_PORT):
        self.host = host
        self.port = port
        self.p = pyaudio.PyAudio()
        self.clients = []
        self.running = True
        self.stats = stats
        
        # Open input stream for microphone capture
        self.audio_stream = self.p.open(
            format=FORMAT,
            channels=CHANNELS,
            rate=RATE,
            input=True,
            frames_per_buffer=CHUNK
        )

    def accept_clients(self, server_socket):
        while self.running:
            try:
                client_socket, client_address = server_socket.accept()
                logging.info(f"Audio Client {client_address} connected")
                self.clients.append(client_socket)
                self.stats.update_clients(audio_count=len(self.clients))
            except Exception as e:
                if self.running:
                    logging.error(f"Error accepting audio client: {e}")

    def stream_audio(self):
        while self.running:
            try:
                audio_data = self.audio_stream.read(CHUNK, exception_on_overflow=False)
                dead_clients = []
                for client in self.clients:
                    try:
                        client.sendall(audio_data)
                    except Exception as e:
                        logging.error(f"Error sending audio to client: {e}")
                        dead_clients.append(client)

                for client in dead_clients:
                    self.clients.remove(client)
                    self.stats.update_clients(audio_count=len(self.clients))
                    try:
                        client.close()
                    except:
                        pass
            except Exception as e:
                logging.error(f"Audio streaming error: {e}")
                break

    def start(self):
        server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_socket.bind((self.host, self.port))
        server_socket.listen(MAX_CLIENTS)
        logging.info(f"Audio Server listening on {self.host}:{self.port}")

        accept_thread = threading.Thread(
            target=self.accept_clients,
            args=(server_socket,),
            name="AudioAcceptor"
        )
        accept_thread.daemon = True
        accept_thread.start()

        stream_thread = threading.Thread(
            target=self.stream_audio,
            name="AudioStreamer"
        )
        stream_thread.daemon = True
        stream_thread.start()

        return server_socket

    def stop(self):
        self.running = False
        for client in self.clients:
            try:
                client.close()
            except:
                pass
        self.audio_stream.stop_stream()
        self.audio_stream.close()
        self.p.terminate()

class ClipboardServer:
    def __init__(self, stats, host='0.0.0.0', port=CLIPBOARD_PORT):
        self.host = host
        self.port = port
        self.last_content = None
        self.last_update = time.time()
        self.update_threshold = 0.5
        self.running = True
        self.stats = stats
        
        self.sync_dir = Path.home() / "ClipboardSync"
        self.sync_dir.mkdir(exist_ok=True)
        logging.info(f"Using sync directory: {self.sync_dir}")
        
        self.clients = set()
        self.clients_lock = threading.Lock()

    def get_clipboard(self):
        try:
            content = subprocess.run(
                ['xsel', '--clipboard', '--output'],
                capture_output=True,
                text=True,
                check=True
            ).stdout
            return content.strip() if content else None
        except Exception as e:
            logging.error(f"Failed to get clipboard: {e}")
            return None

    def set_clipboard(self, text):
        if not isinstance(text, str):
            text = str(text)
        try:
            process = subprocess.Popen(['xsel', '--clipboard', '--input'], stdin=subprocess.PIPE)
            process.communicate(input=text.encode())
            process = subprocess.Popen(['xsel', '--primary', '--input'], stdin=subprocess.PIPE)
            process.communicate(input=text.encode())
            return True
        except Exception as e:
            logging.error(f"Error setting clipboard: {e}")
            return False

    def broadcast_to_clients(self, data, skip_client=None):
        try:
            json_str = json.dumps(data)
            
            with self.clients_lock:
                disconnected = set()
                for client in self.clients:
                    if client == skip_client:
                        continue
                    try:
                        message = json_str.encode() + b'\n'
                        client.sendall(message)
                        client.sendall(b'OK\n')
                    except Exception as e:
                        logging.error(f"Failed to send to client: {e}")
                        disconnected.add(client)
                
                for client in disconnected:
                    self.clients.discard(client)
                    try:
                        client.close()
                    except:
                        pass
                
                self.stats.update_clients(clipboard_count=len(self.clients))
        except Exception as e:
            logging.error(f"Broadcast error: {e}")

    def handle_client(self, client_socket, address):
        logging.info(f"New clipboard connection from {address}")
        
        with self.clients_lock:
            self.clients.add(client_socket)
            self.stats.update_clients(clipboard_count=len(self.clients))
        
        last_monitor_content = None
        buffer = ""
        
        try:
            while self.running:
                current = self.get_clipboard()
                if current and current != last_monitor_content:
                    now = time.time()
                    if (now - self.last_update) > self.update_threshold:
                        data = {
                            "type": "text",
                            "content": current,
                            "filename": "",
                            "timestamp": time.strftime('%Y-%m-%dT%H:%M:%S%z')
                        }
                        self.broadcast_to_clients(data)
                        last_monitor_content = current
                        self.last_update = now
                
                client_socket.settimeout(0.1)
                try:
                    data = client_socket.recv(4096)
                    if not data:
                        raise ConnectionError("Client disconnected")
                    
                    chunk = data.decode()
                    buffer += chunk
                    
                    while '\n' in buffer:
                        line, buffer = buffer.split('\n', 1)
                        line = line.strip()
                        if line and line != "OK":
                            try:
                                data = json.loads(line)
                                content = data.get("content", "")
                                
                                if data.get("type") == "file":
                                    file_path = self.sync_dir / data["filename"]
                                    file_content = base64.b64decode(data["content"])
                                    with open(file_path, 'wb') as f:
                                        f.write(file_content)
                                    self.set_clipboard(str(file_path))
                                else:
                                    self.set_clipboard(content)
                                    self.broadcast_to_clients(data, skip_client=client_socket)
                                
                                client_socket.sendall(b'OK\n')
                                self.last_update = time.time()
                                last_monitor_content = content
                                
                            except json.JSONDecodeError as e:
                                logging.error(f"JSON decode error: {e}")
                            except Exception as e:
                                logging.error(f"Error processing data: {e}")
                        
                except socket.timeout:
                    continue
                except Exception as e:
                    logging.error(f"Client error: {e}")
                    raise
                    
        except Exception as e:
            logging.error(f"Clipboard client error: {e}")
        finally:
            with self.clients_lock:
                self.clients.discard(client_socket)
                self.stats.update_clients(clipboard_count=len(self.clients))
            try:
                client_socket.close()
            except:
                pass

    def start(self):
        server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_socket.bind((self.host, self.port))
        server_socket.listen(MAX_CLIENTS)
        logging.info(f"Clipboard Server listening on {self.host}:{self.port}")

        def accept_clients():
            while self.running:
                try:
                    client_socket, address = server_socket.accept()
                    thread = threading.Thread(
                        target=self.handle_client,
                        args=(client_socket, address),
                        name=f"ClipboardClient-{address}",
                        daemon=True
                    )
                    thread.start()
                except Exception as e:
                    if self.running:
                        logging.error(f"Error accepting clipboard client: {e}")

        accept_thread = threading.Thread(target=accept_clients, name="ClipboardAcceptor", daemon=True)
        accept_thread.start()

        return server_socket

    def stop(self):
        self.running = False
        with self.clients_lock:
            for client in self.clients:
                try:
                    client.close()
                except:
                    pass

class UnifiedServer:
    def __init__(self):
        self.setup_logging()
        self.stats = ServerStats()
        self.audio_server = AudioServer(self.stats)
        self.clipboard_server = ClipboardServer(self.stats)
        self.running = False

    def setup_logging(self):
        log_dir = Path.home() / 'UnifiedServer' / 'logs'
        log_dir.mkdir(exist_ok=True, parents=True)
        
        log_file = log_dir / f"server_{datetime.now().strftime('%Y%m%d')}.log"
        handler = RotatingFileHandler(
            log_file,
            maxBytes=5*1024*1024,
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
        
        console_handler = logging.StreamHandler()
        console_handler.setFormatter(formatter)
        logger.addHandler(console_handler)
        
        logging.info("Unified Server logging initialized")

    def log_server_stats(self):
        while self.running:
            stats = self.stats.get_stats()
            logging.info("Server Statistics:")
            for key, value in stats.items():
                logging.info(f"  {key}: {value}")
            time.sleep(300)  # Log every 5 minutes

    def start(self):
        self.running = True
        
        # Start stats logging
        stats_thread = threading.Thread(
            target=self.log_server_stats,
            name="StatsLogger"
        )
        stats_thread.daemon = True
        stats_thread.start()

        try:
            # Start both servers
            audio_socket = self.audio_server.start()
            clipboard_socket = self.clipboard_server.start()

            logging.info(f"Unified Server running:")
            logging.info(f"  Audio Server: {HOST}:{AUDIO_PORT}")
            logging.info(f"  Clipboard Server: {HOST}:{CLIPBOARD_PORT}")

            # Keep main thread alive
            while self.running:
                time.sleep(1)

        except KeyboardInterrupt:
            logging.info("Shutting down unified server...")
        except Exception as e:
            logging.error(f"Server error: {e}")
            logging.debug(traceback.format_exc())
        finally:
            self.running = False
            self.audio_server.stop()
            self.clipboard_server.stop()
            
            try:
                audio_socket.close()
                clipboard_socket.close()
            except:
                pass
            
            logging.info("Unified Server shutdown complete")

if __name__ == "__main__":
    server = UnifiedServer()
    server.start()
