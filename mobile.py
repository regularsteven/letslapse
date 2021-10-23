from http import server
import socketserver
from os import system, path

PORT = 9191




class MyHttpRequestHandler(server.BaseHTTPRequestHandler):
    def do_GET(self):
        print((self.path))
        self.send_response(200)
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        self.wfile.write(bytes("server running", "utf8"))


handler_object = MyHttpRequestHandler

my_server = socketserver.TCPServer(("", PORT), handler_object)
print("my_server running on PORT" + str(PORT))
# Star the server
my_server.serve_forever()
