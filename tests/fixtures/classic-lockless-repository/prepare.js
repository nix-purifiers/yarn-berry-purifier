const isOdd = require("is-odd");
require("fs").writeFileSync("built.js", `module.exports = "classic resolved and prepared (3 is odd: ${isOdd(3)})";\n`);
