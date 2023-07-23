import socketserver

from letslapse.routes import MyHttpRequestHandler


PORT = 80

def start_server():
    # Create an object of the above class
    handler_object = MyHttpRequestHandler

    my_server = socketserver.TCPServer(("", PORT), handler_object)
    print("my_server running on PORT" + str(PORT))
    # Star the server
    my_server.serve_forever()


# Define other routes and handlers here

if __name__ == '__main__':
    start_server()  # For testing purposes
