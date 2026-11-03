// SPDX-License-Identifier: MIT
// Native Yarn dependency hooks bind coordinates to Nix identities; archives
// and publication metadata stay unchanged.
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

module.exports = ({python, tools}) => {
  const contexts = new Map();
  function context(root, lockfile, requested, refresh = false) {
    if (requested === undefined && process.env.BERRY_PURIFIER_PROJECT_INPUTS) return {
      projectInputs: JSON.parse(process.env.BERRY_PURIFIER_PROJECT_INPUTS),
      views: JSON.parse(process.env.BERRY_PURIFIER_INPUT_VIEWS || '[]'),
    };
    let previous = [];
    try { previous = JSON.parse(fs.readFileSync(lockfile)).projectInputs || []; } catch {}
    if (!requested?.length && !previous.length) return {projectInputs:[], views:[]};
    const key = JSON.stringify([root, lockfile, requested ?? null, refresh, previous]);
    if (contexts.has(key)) return contexts.get(key);
    const result = spawnSync(python, [path.join(__dirname,'project-inputs.py'),tools,lockfile,
      path.join(path.dirname(lockfile),'.yarn-berry-purifier/inputs'),JSON.stringify(requested ?? null),String(refresh)],
      {encoding:'utf8',stderr:'inherit'});
    if (result.status !== 0) throw new Error('yarn-berry-purifier: Nix could not realize the project inputs');
    const value = JSON.parse(result.stdout);
    contexts.set(key,value);
    return value;
  }
  function views(root, lockfile) {
    if (process.env.BERRY_PURIFIER_INPUT_VIEWS) return JSON.parse(process.env.BERRY_PURIFIER_INPUT_VIEWS);
    return context(root,lockfile).views;
  }
  function activate(value) {
    process.env.BERRY_PURIFIER_PROJECT_INPUTS = JSON.stringify(value.projectInputs);
    process.env.BERRY_PURIFIER_INPUT_VIEWS = JSON.stringify(value.views);
  }
  const catalogs = new Map();
  function reduceDependency(dependency, views, structUtils, semverUtils) {
    if (!views.length) return dependency;
    const key = JSON.stringify(views);
    let grouped = catalogs.get(key);
    if (!grouped) {
      grouped = new Map();
      for (const view of views) {
        for (const item of JSON.parse(fs.readFileSync(view.catalog)).modules) {
          const versions = grouped.get(item.name) || [];
          const same = versions.find(previous=>previous.version === item.version);
          if (same && same.integrity !== item.integrity) throw new Error(`conflicting Nix npm artifacts: ${item.name}@${item.version}`);
          if (same) same.primary ||= item.primary;
          else versions.push({...item,repository:view.repository});
          grouped.set(item.name,versions);
        }
      }
      catalogs.set(key,grouped);
    }
    let actual = structUtils.stringifyIdent(dependency);
    let wanted = dependency.range.replace(/^npm:/,'');
    if (dependency.range.startsWith('npm:')) {
      try {
        const alias = structUtils.parseDescriptor(wanted,true);
        actual = structUtils.stringifyIdent(alias);
        wanted = alias.range;
      } catch {}
    }
    const versions = grouped.get(actual);
    if (!versions) return dependency;
    const exact = versions.find(item=>item.version === wanted);
    const archive = versions.find(item=>dependency.range.includes('/'+item.archive));
    const primaries = versions.filter(item=>item.primary);
    const matching = versions.filter(item=>{
      try {return semverUtils.satisfiesWithPrereleases(item.sourceVersion,wanted);} catch {return false;}
    });
    const selected = exact || archive || (primaries.length === 1 ? primaries[0]
      : matching.length === 1 ? matching[0] : versions.length === 1 ? versions[0] : null);
    if (!selected) throw new Error(`Nix inputs supply multiple versions without a unique producer: ${actual}`);
    return structUtils.makeDescriptor(dependency,'file:'+path.join(selected.repository,selected.archive));
  }
  return {context, views, activate, reduceDependency};
};
