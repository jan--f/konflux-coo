#!/bin/bash

# build-override-snapshot.sh
#
# Build an "override" Snapshot that is consistent with the operand image
# references dictated by the code in this repository.
#
# The component images come straight from `bundle-patches/render_templates`
# (the same pinned digests that get baked into the bundle CSV's
# .spec.relatedImages at build time). Component names are resolved offline from
# the `.tekton/*-push.yaml` PipelineRun definitions by matching the image
# repository. No cluster access is required.
#
# Because the Snapshot is generated from the exact digests the code points to,
# it is self-consistent with the bundle that would be built from the same
# checkout. It is up to the user to ensure those references build a correct
# bundle.

set -euo pipefail

DEFAULT_APPLICATION="cluster-observability-operator-1-5"
DEFAULT_BUNDLE_COMPONENT="cluster-observability-operator-bundle-1-5"
DEFAULT_RENDER_TEMPLATES="bundle-patches/render_templates"
DEFAULT_TEKTON_DIR=".tekton"

application="$DEFAULT_APPLICATION"
bundle_component="$DEFAULT_BUNDLE_COMPONENT"
render_templates="$DEFAULT_RENDER_TEMPLATES"
tekton_dir="$DEFAULT_TEKTON_DIR"
namespace=""
output=""
snapshot_name=""
bundle_image=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Build an override Snapshot from the operand image references dictated by the
code (bundle-patches/render_templates). Component names are resolved offline
from .tekton/*-push.yaml. No cluster access is required.

OPTIONS:
  -a, --application NAME        Konflux application name for spec.application
                               (default: $DEFAULT_APPLICATION)
  -n, --namespace NAME          metadata.namespace (default: omitted)
  -o, --output FILE             Write the Snapshot YAML to FILE (default: stdout)
      --name NAME               metadata.name of the generated Snapshot
                               (default: <application>-override-<timestamp>)
      --render-templates FILE   Path to render_templates
                               (default: $DEFAULT_RENDER_TEMPLATES)
      --tekton-dir DIR          Directory with *-push.yaml PipelineRuns
                               (default: $DEFAULT_TEKTON_DIR)
      --bundle-image IMAGE      Also include the bundle component with this
                               image ref (repo@sha256:...). The bundle digest
                               is not tracked in code, so it must be supplied
                               explicitly if you want it in the Snapshot.
      --bundle-component NAME   Component name used for --bundle-image
                               (default: $DEFAULT_BUNDLE_COMPONENT)
  -h, --help                    Show this help

REQUIREMENTS:
  - awk, sed, grep (coreutils)

EXAMPLES:
  $0
  $0 -o override-snapshot.yaml
  $0 -n cluster-observabilit-tenant -o override-snapshot.yaml
  $0 --bundle-image quay.io/.../cluster-observability-operator-bundle@sha256:abc...
EOF
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--application) application="$2"; shift 2 ;;
        -n|--namespace) namespace="$2"; shift 2 ;;
        -o|--output) output="$2"; shift 2 ;;
        --name) snapshot_name="$2"; shift 2 ;;
        --render-templates) render_templates="$2"; shift 2 ;;
        --tekton-dir) tekton_dir="$2"; shift 2 ;;
        --bundle-image) bundle_image="$2"; shift 2 ;;
        --bundle-component) bundle_component="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (use --help)" ;;
    esac
done

[[ -f "$render_templates" ]] || die "render_templates not found: $render_templates"
[[ -d "$tekton_dir" ]] || die "tekton dir not found: $tekton_dir"

if [[ -z "$snapshot_name" ]]; then
    snapshot_name="${application}-override-$(date +%Y%m%d-%H%M%S)"
fi

########################################
# 1. Map image-repo-base -> component name (offline, from .tekton push files)
########################################
declare -A repo_to_component
shopt -s nullglob
push_files=("$tekton_dir"/*-push.yaml)
shopt -u nullglob
[[ ${#push_files[@]} -gt 0 ]] || die "no *-push.yaml files found in $tekton_dir"

for f in "${push_files[@]}"; do
    comp=$(sed -n 's/.*appstudio\.openshift\.io\/component: *//p' "$f" | head -1)
    # output-image value is on the line following "name: output-image"
    img=$(awk '/name: output-image/{getline; if ($1=="value:") {print $2}}' "$f" | head -1)
    [[ -z "$comp" || -z "$img" ]] && continue
    base="${img%%@*}"     # strip @digest if present
    base="${base%%:*}"    # strip :tag (e.g. :{{revision}})
    repo_to_component["$base"]="$comp"
done

[[ ${#repo_to_component[@]} -gt 0 ]] || die "could not derive any component mappings from $tekton_dir"

########################################
# 2. Read pinned image refs from render_templates
########################################
mapfile -t image_refs < <(grep -oE 'quay\.io/[^"[:space:]]+@sha256:[a-f0-9]+' "$render_templates" | sort -u)
[[ ${#image_refs[@]} -gt 0 ]] || die "no pinned image refs (repo@sha256:...) found in $render_templates"

log "Found ${#image_refs[@]} pinned image ref(s) in $render_templates"

########################################
# 3. Build the component list (name + containerImage)
########################################
# entries: newline-separated "name<TAB>image"
entries=""
missing=0
for ref in "${image_refs[@]}"; do
    base="${ref%%@*}"
    comp="${repo_to_component[$base]:-}"
    if [[ -z "$comp" ]]; then
        log "WARN: no .tekton component matches image repo: $base - skipping"
        missing=$((missing + 1))
        continue
    fi
    entries+="${comp}	${ref}"$'\n'
    log "  + $comp -> $ref"
done

# Optionally add the bundle component (digest is not code-tracked).
if [[ -n "$bundle_image" ]]; then
    entries+="${bundle_component}	${bundle_image}"$'\n'
    log "  + $bundle_component -> $bundle_image (bundle)"
fi

[[ -n "$entries" ]] || die "no components resolved; nothing to write"

# Sort by component name for deterministic output.
entries=$(printf '%s' "$entries" | sort)

########################################
# 4. Emit the override Snapshot YAML
########################################
emit() {
    printf 'apiVersion: appstudio.redhat.com/v1alpha1\n'
    printf 'kind: Snapshot\n'
    printf 'metadata:\n'
    printf '  name: %s\n' "$snapshot_name"
    [[ -n "$namespace" ]] && printf '  namespace: %s\n' "$namespace"
    printf '  labels:\n'
    printf '    test.appstudio.openshift.io/type: override\n'
    printf 'spec:\n'
    printf '  application: %s\n' "$application"
    printf '  components:\n'
    while IFS=$'\t' read -r name image; do
        [[ -z "$name" ]] && continue
        printf '    - name: %s\n' "$name"
        printf '      containerImage: %s\n' "$image"
    done <<< "$entries"
}

if [[ -n "$output" ]]; then
    emit > "$output"
    log "Wrote override Snapshot to $output"
    log "Apply with: kubectl create -f $output ${namespace:+-n $namespace}"
else
    emit
fi

if [[ "$missing" -gt 0 ]]; then
    log "NOTE: $missing image ref(s) had no matching component and were skipped"
fi
