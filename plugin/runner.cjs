// SPDX-License-Identifier: MIT
// Rebind supplied identities with native Yarn, keeping the committed lock
// intact across architectures and changes in the installed purifier.
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const inputs = require('./npm-inputs.cjs')({python:'@python@',tools:'@projectInputsTool@'});
const {readLock} = require('./purifier.cjs').internals;
const [program,...args] = process.argv.slice(2);
const execute = (argv,env=process.env) => {
  const result = spawnSync(program,argv,{stdio:'inherit',env});
  return result.status ?? 1;
};
if (["--version","-v","--help","-h"].includes(args[0])) process.exit(execute(args));
let root = process.cwd();
let lockfile = process.env.YARN_BERRY_PURIFIER_LOCKFILE;
if (lockfile) {
  while (!fs.existsSync(path.join(root,'package.json')) && path.dirname(root)!==root) root=path.dirname(root);
  lockfile=path.resolve(lockfile);
} else {
  while (!fs.existsSync(path.join(root,'yarn.lock')) && path.dirname(root)!==root) root=path.dirname(root);
  lockfile=path.join(root,'yarn-berry-purifier.lock.json');
}
let pins=[];
try {pins=JSON.parse(fs.readFileSync(lockfile)).projectInputs || [];} catch {}
const native=path.join(root,'yarn.lock');
const tool=path.resolve(process.env.YARN_BERRY_PURIFIER_TOOL_LOCKFILE || native);
if (!pins.length && tool===native) process.exit(execute(args));
const metadata=readLock(lockfile,tool);
const context=inputs.context(root,lockfile);
inputs.activate(context);
const saved=fs.existsSync(native)?fs.readFileSync(native):null;
let code=1;
let updated=null;
const mutating=["add","remove","up","import","dedupe","set","version","patch-commit"].includes(args[0]);
try {
  if (tool!==native) fs.copyFileSync(tool,native);
  process.env.BERRY_PURIFIER_ORIGINAL_INPUTS_HASH=metadata.inputsHash;
  process.env.BERRY_PURIFIER_NATIVE_CONTEXT="1";
  if (context.views.length) {
    const prepared=spawnSync(program,['install','--mode=skip-build'],{stdio:['inherit',2,2],env:{...process.env,YARN_ENABLE_IMMUTABLE_INSTALLS:'false'}});
    code=prepared.status ?? 1;
    if (code===0) code=execute(args);
  } else code=execute(args);
  if (mutating && code===0 && fs.existsSync(native)) updated=fs.readFileSync(native);
} finally {
  if (saved===null) fs.rmSync(native,{force:true});
  else fs.writeFileSync(native,saved);
}
if (updated!==null) fs.writeFileSync(tool,updated);
process.exit(code);
