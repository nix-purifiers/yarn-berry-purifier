// A registry for the publish check. It answers every metadata request
// with 404, as a registry does for a package it has never seen, and
// writes the body of each publish request (PUT) to the file named by its
// second argument. It writes the port it listens on to the file named by
// its first argument.
const fs = require("fs");
const http = require("http");

const [portFile, bodyFile] = process.argv.slice(2);

const server = http.createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    if (request.method === "PUT") {
      fs.writeFileSync(bodyFile, Buffer.concat(chunks));
      response.writeHead(201, { "content-type": "application/json" });
      response.end('{"ok":true}');
    } else {
      response.writeHead(404, { "content-type": "application/json" });
      response.end('{"error":"not_found"}');
    }
  });
});

server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
