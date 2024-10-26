#!/usr/bin/env python3
import socket
import threading
import win32clipboard
import win32con
import pyaudio
import time
import base64
import os
import json
import sys
import traceback
from pathlib import Path
import logging
from logging.handlers import RotatingFileHandler
import zlib
from queue import Queue
from datetime import datetime
import hashlib
from typing import Optional, Dict, List, Any

# Configuration
CHUNK = 1024
FORMAT = pyaudio.paInt16
CHANNELS = 2
RATE = 44100
CLIPBOARD_PORT = 5000
AUDIO_PORT = 5001
MAX_CHUNK_SIZE = 1024 * 1024  # 1MB chunks for large files
MAX_FILE_SIZE = 100 * 1024 * 1024  # 100MB max file size
MAX_TOTAL_SIZE = 500 * 1024 * 1024  # 500MB max total size
KEEP_ALIVE_INTERVAL = 1.0
RECONNECT_DELAY = 5
PROGRESS_UPDATE_INTERVAL = 0.5

# Error Codes
class ErrorCodes:
    SUCCESS = 0
    CLIPBOARD_ACCESS_ERROR = 100
    FILE_ACCESS_ERROR = 200
    NETWORK_ERROR = 300
    AUDIO_ERROR = 400
    COMPRESSION_ERROR = 500

class TransferProgress:
    def __init__(self, total_size: int, filename: str):
        self.total_size = total_size
        self.current_size = 0
        self.start_time = time.time()
        self.filename = filename
        self.speed = 0.0
        self.last_update = time.time()
        self.last_size = 0

    def update(self, bytes_transferred: int):
        self.current_size += bytes_transferred
        current_time = time.time()
        time_diff = current_time - self.last_update
        
        if time_diff >= PROGRESS_UPDATE_INTERVAL:
            size_diff = self.current_size - self.last_size
            self.speed = size_diff / time_diff
            self.last_update = current_time
            self.last_size = self.current_size
            self._log_progress()

    def _log_progress(self):
        percentage = (self.current_size / self.total_size) * 100
        speed_mb = self.speed / (1024 * 1024)
        remaining_bytes = self.total_size - self.current_size
        
        if self.speed > 0:
            eta_seconds = remaining_bytes / self.speed
            eta_str = time.strftime('%M:%S', time.gmtime(eta_seconds))
        else:
            eta_str = "calculating..."

        logging.info(f"Transfer Progress - {self.filename}")
        logging.info(f"Progress: {percentage:.1f}% | Speed: {speed_mb:.2f} MB/s | ETA: {eta_str}")

class AudioHandler:
    def __init__(self):
        self.p = pyaudio.PyAudio()
        self.streams = {'input': None, 'output': None}
        
    def setup_streams(self):
        try:
            self.streams['input'] = self.p.open(
                format=FORMAT,
                channels=CHANNELS,
                rate=RATE,
                input=True,
                frames_per_buffer=CHUNK
            )
            
            self.streams['output'] = self.p.open(
                format=FORMAT,
                channels=CHANNELS,
                rate=RATE,
                output=True,
                frames_per_buffer=CHUNK
            )
            logging.info("Audio streams initialized successfully")
        except Exception as e:
            logging.error(f"Error setting up audio streams: {str(e)}")
            logging.debug(f"Audio setup error details: {traceback.format_exc()}")
            raise RuntimeError(f"Audio initialization failed: {str(e)}")

    def cleanup(self):
        for stream_name, stream in self.streams.items():
            if stream:
                try:
                    stream.stop_stream()
                    stream.close()
                    logging.debug(f"Closed {stream_name} audio stream")
                except Exception as e:
                    logging.error(f"Error closing {stream_name} stream: {str(e)}")
        
        try:
            self.p.terminate()
            logging.info("Audio system terminated successfully")
        except Exception as e:
            logging.error(f"Error terminating audio system: {str(e)}")

class ClipboardHandler:
    def __init__(self):
        self.last_content = None
        self.last_hash = None
        self.transfer_queue = Queue()
        self.clipboard_dir = Path.home() / 'ClipboardSync'
        self.clipboard_dir.mkdir(exist_ok=True)
        self._clipboard_lock = threading.Lock()
        self.current_transfer = None
        
    def _calculate_content_hash(self, content: Dict[str, Any]) -> Optional[str]:
        try:
            if content['type'] == 'text':
                return hashlib.sha256(content['data'].encode('utf-8')).hexdigest()
            elif content['type'] == 'files':
                file_hashes = []
                for file_info in content['files']:
                    file_hash = hashlib.sha256(
                        f"{file_info['name']}:{file_info['size']}".encode('utf-8')
                    ).hexdigest()
                    file_hashes.append(file_hash)
                return hashlib.sha256(''.join(sorted(file_hashes)).encode('utf-8')).hexdigest()
        except Exception as e:
            logging.error(f"Error calculating content hash: {str(e)}")
            return None

    def is_new_content(self, content: Optional[Dict[str, Any]]) -> bool:
        if content is None:
            return False
            
        current_hash = self._calculate_content_hash(content)
        if current_hash == self.last_hash:
            logging.debug("Duplicate content detected, skipping")
            return False
            
        self.last_hash = current_hash
        return True

    def get_clipboard_content(self) -> Optional[Dict[str, Any]]:
        with self._clipboard_lock:
            try:
                win32clipboard.OpenClipboard()
                
                # Try text first
                if win32clipboard.IsClipboardFormatAvailable(win32con.CF_UNICODETEXT):
                    try:
                        data = win32clipboard.GetClipboardData(win32con.CF_UNICODETEXT)
                        win32clipboard.CloseClipboard()
                        content = {'type': 'text', 'data': data}
                        return content if self.is_new_content(content) else None
                    except Exception as e:
                        logging.error(f"Error getting text from clipboard: {str(e)}")
                        logging.debug(f"Text clipboard error details: {traceback.format_exc()}")
                
                # Try files
                elif win32clipboard.IsClipboardFormatAvailable(win32con.CF_HDROP):
                    try:
                        files = win32clipboard.GetClipboardData(win32con.CF_HDROP)
                        win32clipboard.CloseClipboard()
                        content = self._process_files(files)
                        return content if self.is_new_content(content) else None
                    except Exception as e:
                        logging.error(f"Error getting files from clipboard: {str(e)}")
                        logging.debug(f"File clipboard error details: {traceback.format_exc()}")
                
                win32clipboard.CloseClipboard()
            except Exception as e:
                logging.error(f"Clipboard access error: {str(e)}")
                logging.debug(f"Clipboard access error details: {traceback.format_exc()}")
                self._ensure_clipboard_closed()
            return None

    def _process_files(self, files: List[str]) -> Optional[Dict[str, Any]]:
        try:
            processed_files = []
            total_size = 0
            skipped_files = []
            
            # First pass: validate files and check sizes
            for file_path in files:
                if not os.path.exists(file_path):
                    logging.warning(f"File not found: {file_path}")
                    skipped_files.append((file_path, "File not found"))
                    continue
                    
                size = os.path.getsize(file_path)
                if size > MAX_FILE_SIZE:
                    logging.warning(f"File too large, skipping: {file_path} ({size} bytes)")
                    skipped_files.append((file_path, f"File too large (max {MAX_FILE_SIZE} bytes)"))
                    continue
                    
                total_size += size
                if total_size > MAX_TOTAL_SIZE:
                    logging.warning("Total file size limit exceeded, some files will be skipped")
                    skipped_files.append((file_path, "Total size limit exceeded"))
                    break
                
                processed_files.append((file_path, size))
            
            if skipped_files:
                for file_path, reason in skipped_files:
                    logging.warning(f"Skipped {file_path}: {reason}")
            
            # Second pass: process validated files
            result_files = []
            for file_path, size in processed_files:
                try:
                    self.current_transfer = TransferProgress(size, os.path.basename(file_path))
                    
                    with open(file_path, 'rb') as f:
                        file_data = f.read()
                        compressed_data = zlib.compress(file_data)
                        encoded_data = base64.b64encode(compressed_data).decode('utf-8')
                        
                        compression_ratio = (len(compressed_data) / len(file_data)) * 100
                        logging.info(f"File compression: {compression_ratio:.1f}% of original size")
                        
                        file_info = {
                            'name': os.path.basename(file_path),
                            'size': size,
                            'data': encoded_data,
                            'compressed': True
                        }
                        result_files.append(file_info)
                        logging.info(f"Processed file: {file_path} ({size} bytes)")
                        
                        self.current_transfer = None
                except Exception as e:
                    logging.error(f"Error processing file {file_path}: {str(e)}")
                    logging.debug(f"File processing error details: {traceback.format_exc()}")
                    continue
            
            if result_files:
                return {'type': 'files', 'files': result_files}
            return None
            
        except Exception as e:
            logging.error(f"Error in file processing: {str(e)}")
            logging.debug(f"File processing error details: {traceback.format_exc()}")
            return None

    def set_clipboard_content(self, content: Dict[str, Any]):
        if not self.is_new_content(content):
            return

        with self._clipboard_lock:
            try:
                if content['type'] == 'text':
                    self._set_text_content(content['data'])
                elif content['type'] == 'files':
                    self._set_file_content(content['files'])
            except Exception as e:
                logging.error(f"Error setting clipboard content: {str(e)}")
                logging.debug(f"Clipboard set error details: {traceback.format_exc()}")
                self._ensure_clipboard_closed()

    def _set_text_content(self, text_data: str):
        retry_count = 3
        for attempt in range(retry_count):
            try:
                win32clipboard.OpenClipboard()
                win32clipboard.EmptyClipboard()
                win32clipboard.SetClipboardText(text_data, win32con.CF_UNICODETEXT)
                win32clipboard.CloseClipboard()
                logging.info("Text content set to clipboard")
                return
            except Exception as e:
                logging.error(f"Error setting text content (attempt {attempt + 1}): {str(e)}")
                self._ensure_clipboard_closed()
                if attempt < retry_count - 1:
                    time.sleep(0.5)

    def _set_file_content(self, files: List[Dict[str, Any]]):
        self._cleanup_old_files()
        
        saved_files = []
        total_size = sum(file_info['size'] for file_info in files)
        current_transfer = TransferProgress(total_size, "Multiple files" if len(files) > 1 else files[0]['name'])
        
        for file_info in files:
            try:
                target_path = self.clipboard_dir / file_info['name']
                file_data = base64.b64decode(file_info['data'])
                
                if file_info.get('compressed', False):
                    file_data = zlib.decompress(file_data)
                
                with open(target_path, 'wb') as f:
                    f.write(file_data)
                saved_files.append(str(target_path))
                
                current_transfer.update(file_info['size'])
                logging.info(f"Saved file: {file_info['name']} ({file_info['size']} bytes)")
            except Exception as e:
                logging.error(f"Error saving file {file_info['name']}: {str(e)}")
                logging.debug(f"File save error details: {traceback.format_exc()}")
        
        if saved_files:
            self._set_files_to_clipboard(saved_files)

    def _set_files_to_clipboard(self, file_paths: List[str]):
        retry_count = 3
        for attempt in range(retry_count):
            try:
                file_list = '\0'.join(file_paths + [''])
                win32clipboard.OpenClipboard()
                win32clipboard.EmptyClipboard()
                win32clipboard.SetClipboardData(win32con.CF_HDROP, file_list)
                win32clipboard.CloseClipboard()
                logging.info(f"Files saved to clipboard: {', '.join(file_paths)}")
                return
            except Exception as e:
                logging.error(f"Error setting files to clipboard (attempt {attempt + 1}): {str(e)}")
                self._ensure_clipboard_closed()
                if attempt < retry_count - 1:
                    time.sleep(0.5)

    def _ensure_clipboard_closed(self):
        try:
            win32clipboard.CloseClipboard()
        except:
            pass

    def _cleanup_old_files(self):
        try:
            for file_path in self.clipboard_dir.glob('*'):
                try:
                    if file_path.is_file():
                        file_path.unlink()
                except Exception as e:
                    logging.error(f"Error deleting file {file_path}: {str(e)}")
        except Exception as e:
            logging.error(f"Error cleaning up directory: {str(e)}")

class UnifiedClient:
    def __init__(self, host: str):
        self.host = host
        self.running = False
        self.clipboard = ClipboardHandler()
        self.audio = AudioHandler()
        self.keep_alive_interval = KEEP_ALIVE_INTERVAL
        self.setup_logging()

    def setup_logging(self):
        log_dir = Path.home() / 'ClipboardSync' / 'logs'
        log_dir.mkdir(exist_ok=True, parents=True)
        
        log_file = log_dir / f"clipboard_sync_{datetime.now().strftime('%Y%m%d')}.log"
        
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
        
        logging.info("Logging initialized")

    def _send_keep_alive(self, sock: socket.socket) -> bool:
        try:
            keep_alive = json.dumps({'type': 'keep_alive'})
            message = f"{len(keep_alive)}:{keep_alive}".encode('utf-8')
            sock.sendall(message)
            return True
        except Exception as e:
            logging.error(f"Error sending keep-alive: {str(e)}")
            return False

    def _send_data_with_progress(self, sock: socket.socket, data: Dict[str, Any], 
                               progress: Optional[TransferProgress] = None):
        try:
            serialized = json.dumps(data)
            message = f"{len(serialized)}:{serialized}".encode('utf-8')
            
            bytes_sent = 0
            while bytes_sent < len(message):
                sent = sock.send(message[bytes_sent:])
                if sent == 0:
                    raise ConnectionError("Socket connection broken")
                bytes_sent += sent
                
                if progress:
                    progress.update(sent)
                    
        except Exception as e:
            logging.error(f"Error sending data: {str(e)}")
            raise

    def _receive_data_with_progress(self, sock: socket.socket, 
                                  progress: Optional[TransferProgress] = None) -> Optional[Dict[str, Any]]:
        try:
            sock.settimeout(0.1)
            header = b""
            while b":" not in header:
                chunk = sock.recv(1)
                if not chunk:
                    raise ConnectionError("Connection lost while reading header")
                header += chunk

            size = int(header.decode('utf-8').strip(":"))
            data = b""
            remaining = size
            start_time = time.time()

            while remaining > 0 and (time.time() - start_time) < 30:  # 30 second timeout
                chunk = sock.recv(min(remaining, 8192))
                if not chunk:
                    raise ConnectionError("Connection lost while receiving data")
                data += chunk
                remaining -= len(chunk)
                
                if progress:
                    progress.update(len(chunk))

            if remaining > 0:
                raise TimeoutError("Data reception timed out")

            return json.loads(data.decode('utf-8'))

        except socket.timeout:
            return None
        except json.JSONDecodeError as e:
            logging.error(f"Error decoding received data: {str(e)}")
            return None
        except Exception as e:
            logging.error(f"Error receiving data: {str(e)}")
            raise

    def start_audio_sync(self):
        while self.running:
            try:
                logging.info(f"Connecting to audio service {self.host}:{AUDIO_PORT}...")
                audio_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                audio_socket.connect((self.host, AUDIO_PORT))
                audio_socket.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                logging.info("Audio sync connected!")
                
                def receive_audio():
                    while self.running:
                        try:
                            data = audio_socket.recv(CHUNK * 4)
                            if data and self.audio.streams['output']:
                                self.audio.streams['output'].write(data)
                        except Exception as e:
                            if self.running:
                                logging.error(f"Error receiving audio: {str(e)}")
                            break
                            
                def send_audio():
                    while self.running:
                        try:
                            if self.audio.streams['input']:
                                data = self.audio.streams['input'].read(CHUNK, exception_on_overflow=False)
                                audio_socket.send(data)
                        except Exception as e:
                            if self.running:
                                logging.error(f"Error sending audio: {str(e)}")
                            break
                
                receive_thread = threading.Thread(target=receive_audio, name="AudioReceive")
                send_thread = threading.Thread(target=send_audio, name="AudioSend")
                
                receive_thread.start()
                send_thread.start()
                
                receive_thread.join()
                send_thread.join()
                
            except Exception as e:
                if self.running:
                    logging.error(f"Audio connection error: {str(e)}")
                    logging.debug(f"Audio connection error details: {traceback.format_exc()}")
                    time.sleep(RECONNECT_DELAY)
                
            finally:
                try:
                    audio_socket.close()
                except:
                    pass

    def start_clipboard_sync(self):
        last_keep_alive = 0

        while self.running:
            try:
                logging.info(f"Connecting to clipboard service {self.host}:{CLIPBOARD_PORT}...")
                clipboard_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                clipboard_socket.connect((self.host, CLIPBOARD_PORT))
                clipboard_socket.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                logging.info("Clipboard sync connected!")

                while self.running:
                    try:
                        current_time = time.time()
                        
                        # Send keep-alive periodically
                        if current_time - last_keep_alive >= self.keep_alive_interval:
                            if not self._send_keep_alive(clipboard_socket):
                                raise ConnectionError("Keep-alive failed")
                            last_keep_alive = current_time

                        # Check local clipboard for changes
                        current = self.clipboard.get_clipboard_content()
                        if current:  # Already checks for duplicates
                            try:
                                if current['type'] == 'files':
                                    total_size = sum(f['size'] for f in current['files'])
                                    progress = TransferProgress(total_size, 
                                        "Multiple files" if len(current['files']) > 1 
                                        else current['files'][0]['name'])
                                    
                                    for file_info in current['files']:
                                        # Send file info
                                        info = {
                                            'type': 'file_info',
                                            'name': file_info['name'],
                                            'size': file_info['size'],
                                            'compressed': file_info['compressed']
                                        }
                                        self._send_data_with_progress(clipboard_socket, info)
                                        
                                        # Send file data in chunks
                                        chunk_size = 1024 * 1024  # 1MB chunks
                                        data = file_info['data']
                                        for i in range(0, len(data), chunk_size):
                                            chunk = data[i:i + chunk_size]
                                            chunk_data = {
                                                'type': 'file_chunk',
                                                'name': file_info['name'],
                                                'chunk': chunk,
                                                'final': i + chunk_size >= len(data)
                                            }
                                            self._send_data_with_progress(clipboard_socket, 
                                                                        chunk_data, progress)
                                            time.sleep(0.01)  # Prevent overwhelming the network
                                else:
                                    # Send text content
                                    self._send_data_with_progress(clipboard_socket, current)
                                
                                logging.info(f"Sent {current['type']} content successfully")
                            except Exception as e:
                                logging.error(f"Error sending clipboard content: {str(e)}")
                                logging.debug(f"Send error details: {traceback.format_exc()}")
                                raise

                        # Check for incoming data
                        data = self._receive_data_with_progress(clipboard_socket)
                        if data:
                            try:
                                if data.get('type') == 'keep_alive':
                                    continue
                                elif data.get('type') == 'file_info':
                                    progress = TransferProgress(data['size'], data['name'])
                                    file_data = []
                                    
                                    # Receive file chunks
                                    while True:
                                        chunk_data = self._receive_data_with_progress(clipboard_socket, progress)
                                        if not chunk_data or chunk_data['type'] != 'file_chunk':
                                            break
                                            
                                        file_data.append(chunk_data['chunk'])
                                        if chunk_data.get('final'):
                                            break
                                    
                                    # Process complete file
                                    if file_data:
                                        complete_file = {
                                            'type': 'files',
                                            'files': [{
                                                'name': data['name'],
                                                'size': data['size'],
                                                'data': ''.join(file_data),
                                                'compressed': data['compressed']
                                            }]
                                        }
                                        self.clipboard.set_clipboard_content(complete_file)
                                
                                elif data.get('type') == 'text':
                                    self.clipboard.set_clipboard_content(data)

                            except Exception as e:
                                logging.error(f"Error processing received data: {str(e)}")
                                logging.debug(f"Processing error details: {traceback.format_exc()}")
                                raise

                    except Exception as e:
                        logging.error(f"Error in clipboard sync loop: {str(e)}")
                        raise

                    time.sleep(0.1)

            except Exception as e:
                if self.running:
                    logging.error(f"Clipboard connection error: {str(e)}")
                    logging.debug(f"Connection error details: {traceback.format_exc()}")
                    time.sleep(RECONNECT_DELAY)
            finally:
                try:
                    clipboard_socket.close()
                except:
                    pass

    def start(self):
        try:
            self.running = True
            self.audio.setup_streams()
            
            clipboard_thread = threading.Thread(target=self.start_clipboard_sync, 
                                             name="ClipboardSync")
            audio_thread = threading.Thread(target=self.start_audio_sync, 
                                         name="AudioSync")
            
            clipboard_thread.start()
            audio_thread.start()
            
            try:
                while self.running:
                    time.sleep(0.1)
            except KeyboardInterrupt:
                logging.info("Shutting down...")
                self.running = False
                
            clipboard_thread.join()
            audio_thread.join()
            
        except Exception as e:
            logging.error(f"Error in main loop: {str(e)}")
            logging.debug(f"Main loop error details: {traceback.format_exc()}")
        finally:
            self.audio.cleanup()
            logging.info("Cleanup completed")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python windows_client.py <host_ip>")
        sys.exit(1)
        
    host_ip = sys.argv[1]
    client = UnifiedClient(host_ip)
    client.start()
