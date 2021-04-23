const http = require("http");
const fs = require('fs').promises;
const host = 'localhost';
const port = 8000;

const siteRoot = "/assets/";

let indexFile;

const apiData = JSON.stringify([
    { name: "Paulo Coelho", countryOfBirth: "Brazil", yearOfBirth: 1947 },
    { name: "Kahlil Gibran", countryOfBirth: "Lebanon", yearOfBirth: 1883 }
]);


const requestListener = function (req, res) {

    switch (req.url) {
        case "/api":
            res.setHeader("Content-Type", "text/html");
            res.writeHead(200);
            res.end(apiData);
            break
        case "/":
            res.writeHead(200);
            res.end(indexFile);
            break
        default:
            console.log(req.url);
            fs.readFile(__dirname + siteRoot + req.url)
            .then(contents => {
                //res.setHeader("Content-Type", "text/html");
                res.writeHead(200);
                res.end(contents);
            })
            .catch(err => {
                res.writeHead(500);
                res.end(err);
                return;
            });
            //res.end(JSON.stringify({error:"Resource not found - " + req.url}));
        }

};

const server = http.createServer(requestListener);


fs.readFile(__dirname + siteRoot+"/index.html")
    .then(contents => {
        indexFile = contents;
        server.listen(port, host, () => {
            console.log(`Server is running on http://${host}:${port}`);
        });
    })
    .catch(err => {
        console.error(`Could not read index.html file: ${err}`);
        process.exit(1);
    });


server.listen(port, host, () => {
    console.log(`Running on http://${host}:${port}`);
});