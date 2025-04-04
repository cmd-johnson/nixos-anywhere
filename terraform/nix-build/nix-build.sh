#!/usr/bin/env bash
set -efu

declare file attribute nix_options special_args
eval "$(jq -r '@sh "attribute=\(.attribute) file=\(.file) nix_options=\(.nix_options) special_args=\(.special_args)"')"
if [ "${nix_options}" != '{"options":{}}' ]; then
  options=$(echo "${nix_options}" | jq -r '.options | to_entries | map("--option \(.key) \(.value)") | join(" ")')
else
  options=""
fi
if [[ ${special_args-} == "{}" ]]; then
  # no special arguments, proceed as normal
  if [[ -n ${file-} ]] && [[ -e ${file-} ]]; then
    # shellcheck disable=SC2086
    out=$(nix build --no-link --json $options -f "$file" "$attribute")
  else
    # shellcheck disable=SC2086
    out=$(nix build --no-link --json ${options} "$attribute")
  fi
else
  if [[ ${file-} != 'null' ]]; then
    echo "special_args are currently only supported when using flakes!" >&2
    exit 1
  fi
  # pass the args in a pure fashion by extending the original config
  rest="$(echo "${attribute}" | cut -d "#" -f 2)"
  # e.g. config_path=nixosConfigurations.aarch64-linux.myconfig
  config_path="${rest%.config.*}"
  # e.g. config_attribute=config.system.build.toplevel
  config_attribute="config.${rest#*.config.}"

  # e.g. flake_rel="." or flake_rel="github:username/repo/<commit_hash>"
  flake_rel="$(echo "${attribute}" | cut -d "#" -f 1)"

  if [[ -d "${flake_rel}" ]]; then
    # we're looking at a flake directory
    # resolve symlinks and resolve directories to an absolute path
    flake_dir="$(readlink -f "${flake_rel}")"
    # grab flake nar
    flake_nar="$(nix flake prefetch "${flake_dir}" --json | jq -r '.hash')"
    # construct the flake file URL including its hash
    flake_url="file://${flake_dir}/flake.nix?narHash=${flake_nar}"
  else
    # flake_rel is not a directory, assume that it is a flake reference URL already
    flake_url="${flake_rel}"
  fi

  # substitute variables into the template
  nix_expr="(builtins.getFlake ''${flake_url}'').${config_path}.extendModules { specialArgs = builtins.fromJSON ''${special_args}''; }"
  # inject `special_args` into nixos config's `specialArgs`
  # shellcheck disable=SC2086
  out=$(nix build --no-link --json ${options} --expr "${nix_expr}" "${config_attribute}")
fi
printf '%s' "$out" | jq -c '.[].outputs'
