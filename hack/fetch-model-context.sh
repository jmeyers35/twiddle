#!/usr/bin/env bash
set -euo pipefail

if [[ ${OPENROUTER_API_KEY:-} == "" ]]; then
  echo "error: OPENROUTER_API_KEY environment variable is not set" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not installed" >&2
  exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "error: zig is required but not installed" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
default_output="${project_root}/config/model_context.json"
output_path="${1:-${default_output}}"
generated_table="${project_root}/src/model_context_data.zig"

tmp_payload="$(mktemp)"
tmp_processed="$(mktemp)"
cleanup() {
  rm -f "${tmp_payload}" "${tmp_processed}"
}
trap cleanup EXIT

curl --fail --silent --show-error \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
  -H "Accept: application/json" \
  "https://openrouter.ai/api/v1/models" \
  >"${tmp_payload}"

jq 'def first_present($obj; $keys):
      reduce $keys[] as $k (null; if . == null then $obj[$k] else . end);
    def ctx:
      (first_present(.; ["context_length","context_window","max_context","max_context_length"]) //
       first_present((.limits // {}); ["context_length","context_window","context"]) //
       first_present((.architecture // {}); ["context_length","context_window","max_context","max_context_length"]));
    (.data // [])
    | map({ slug: first_present(.; ["id","slug","name","model"]), context_raw: ctx })
    | map(select(.slug != null))
    | map(.context = (if (.context_raw | type) == "number" then (.context_raw | floor)
                      elif (.context_raw | type) == "string" then ((.context_raw | tonumber?) // null)
                      else null end))
    | {
        found: map(select(.context != null)),
        missing: (map(select(.context == null) | .slug) | unique | sort)
      }' \
  "${tmp_payload}" >"${tmp_processed}"

mkdir -p "$(dirname "${output_path}")"

jq '.found
    | sort_by(.slug)
    | reduce .[] as $item ({}; . + { ($item.slug): $item.context })' \
  "${tmp_processed}" >"${output_path}"

zig run "${project_root}/hack/generate_model_context_table.zig" -- \
  --input "${output_path}" \
  --output "${generated_table}"

missing_count=$(jq '.missing | length' "${tmp_processed}")

if [[ ${missing_count} -gt 0 ]]; then
  printf 'warning: missing context_length for %d models\n' "${missing_count}" >&2
fi

entry_count=$(jq '.found | length' "${tmp_processed}")
printf 'wrote %d model context entries to %s\n' "${entry_count}" "${output_path}"
