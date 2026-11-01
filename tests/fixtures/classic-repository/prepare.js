const isOdd = require("is-odd");
require("fs").writeFileSync("built.js", `module.exports = "classic prepared (3 is odd: ${isOdd(3)})";\n`);
