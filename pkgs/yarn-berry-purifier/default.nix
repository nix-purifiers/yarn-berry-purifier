# SPDX-License-Identifier: MIT
#
# The `yarn-berry-purifier` command: `lock`, `prefetch` and `publish`, which
# run the plugin's commands `yarn purifier lock`, `yarn purifier prefetch`
# and `yarn purifier publish` through the `yarn` wrapper, with the
# remaining arguments passed on.
{
  writeShellApplication,
  yarn,
}:
writeShellApplication {
  name = "yarn-berry-purifier";
  runtimeInputs = [ yarn ];
  text = ''
    usage() {
      echo "usage: yarn-berry-purifier lock|prefetch|publish [--lockfile <path>] [options]" >&2
      exit 2
    }
    [ "$#" -ge 1 ] || usage
    command="$1"
    shift
    case "$command" in
      lock | prefetch | publish)
        exec yarn purifier "$command" "$@"
        ;;
      *)
        usage
        ;;
    esac
  '';
}
