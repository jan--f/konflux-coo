#!/bin/bash

# build-override-snapshot.sh
#
# Build an "override" Snapshot that is internally consistent with the operator
# bundle it ships, so it can pass the release-time Conforma / Enterprise
# Contract checks.
#
# WHY THIS EXISTS
# ---------------
# A release fails with `olm.unmapped_references` when the bundle's CSV
# (.spec.relatedImages) pins operand digests that are NOT present (at the same
# digest) as components in the Snapshot. The release step `apply-mapping` can
# then not map those bundle references to their target repositories. This is a
# race: when many operands are rebuilt in parallel each one nudges the bundle,
# so an auto-generated Snapshot can easily pair a bundle with a mismatched set
# of operand digests.
#
# HOW THIS AVOIDS IT
# ------------------
# The operand digests are taken from the *bundle image's own CSV*
# (.spec.relatedImages) - the exact references that will ship - instead of from
# the code. The Snapshot is therefore consistent with the bundle by
# construction. The bundle itself is included as a component too. The digests
# are cross-checked against bundle-patches/render_templates and any divergence
# is reported as a warning (the bundle remains the source of truth).
#
# Each relatedImage is pinned to registry.redhat.io in the CSV; it is mapped
# back to the quay.io build repository (by image name, using the .tekton
# *-push.yaml definitions) because the Snapshot must reference the build-time
# images that carry Konflux signatures and provenance.
#
# For each component the git source reference (url + revision) is read from the
# image's own labels in the registry (org.opencontainers.image.source /
# org.opencontainers.image.revision) and emitted as spec.components[].source.git.
# Without it the release-time Conforma check fails every component with:
#   slsa_source_correlated.source_code_reference_provided
#   "Expected source code reference was not provided for verification"
#
# The bundle image is discovered from the cluster
# (Component/<bundle>.status.lastPromotedImage) unless --bundle-image is given.

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

Build an override Snapshot that is consistent with the operator bundle it ships.
Operand digests come from the bundle CSV's .spec.relatedImages; the bundle image
is discovered from the cluster unless --bundle-image is provided.

OPTIONS:
  -a, --application NAME        Konflux application name for spec.application
                               (default: $DEFAULT_APPLICATION)
  -n, --namespace NAME          Namespace used to discover the bundle image and
                               set metadata.namespace (default: current oc context)
  -o, --output FILE             Write the Snapshot YAML to FILE (default: stdout)
      --name NAME               metadata.name of the generated Snapshot
                               (default: <application>-override-<timestamp>)
      --bundle-image IMAGE      Bundle image ref (repo@sha256:...) to build the
                               Snapshot from. If omitted, it is discovered from
                               Component/<bundle-component>.status.lastPromotedImage.
      --bundle-component NAME   Bundle Component name, used both for discovery and
                               as the bundle's Snapshot component name
                               (default: $DEFAULT_BUNDLE_COMPONENT)
      --render-templates FILE   render_templates used only to cross-check the
                               bundle's operand digests (default: $DEFAULT_RENDER_TEMPLATES)
      --tekton-dir DIR          Directory with *-push.yaml PipelineRuns
                               (default: $DEFAULT_TEKTON_DIR)
  -h, --help                    Show this help

REQUIREMENTS:
  - grep (coreutils)
  - oc (to discover the bundle image and extract its CSV)
  - yq (mikefarah/yq v4) to parse YAML and emit the Snapshot
  - curl, jq (to read each image's git source labels and build component JSON)

EXAMPLES:
  $0 -n cluster-observabilit-tenant -o override-snapshot.yaml
  $0 --bundle-image quay.io/.../cluster-observability-operator-bundle@sha256:abc...
EOF
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v yq >/dev/null 2>&1 || die "yq (mikefarah/yq v4) is required"
command -v oc >/dev/null 2>&1 || die "oc is required"

# Media types we accept when pulling manifests (image indexes and manifests,
# both OCI and Docker schema 2).
_ACCEPT_MANIFESTS="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"

# Obtain an anonymous pull token for a registry repository. Prints an empty
# string if none is needed/available (public repos on quay.io work either way).
_registry_token() {
    local registry="$1" repo="$2"
    case "$registry" in
        quay.io)
            curl -fsSL "https://quay.io/v2/auth?service=quay.io&scope=repository:${repo}:pull" 2>/dev/null \
                | jq -r '.token // empty' 2>/dev/null || true
            ;;
        *) : ;;  # unknown registry: try anonymous
    esac
}

# Read the config Labels (as JSON) for an image reference, following image
# indexes down to the first child manifest. Args: <registry> <repo> <digest>.
_image_labels_json() {
    local registry="$1" repo="$2" digest="$3"
    local base="https://${registry}/v2/${repo}"
    local token auth=()
    token="$(_registry_token "$registry" "$repo")"
    [[ -n "$token" ]] && auth=(-H "Authorization: Bearer $token")

    local manifest
    manifest="$(curl -fsSL "${auth[@]}" -H "Accept: ${_ACCEPT_MANIFESTS}" "${base}/manifests/${digest}")" || return 1

    # If this is an index/manifest-list, descend into the first child manifest.
    if printf '%s' "$manifest" | jq -e '.manifests and (.manifests | length > 0)' >/dev/null 2>&1; then
        local child
        child="$(printf '%s' "$manifest" | jq -r '.manifests[0].digest')"
        manifest="$(curl -fsSL "${auth[@]}" -H "Accept: ${_ACCEPT_MANIFESTS}" "${base}/manifests/${child}")" || return 1
    fi

    local cfg
    cfg="$(printf '%s' "$manifest" | jq -r '.config.digest // empty')"
    [[ -n "$cfg" ]] || return 1
    curl -fsSL "${auth[@]}" "${base}/blobs/${cfg}" | jq '.config.Labels // {}'
}

# Resolve the git source (url + revision) for an image reference by reading its
# labels. Prints "url<TAB>revision" on success; returns non-zero on failure.
resolve_git_source() {
    local ref="$1"                 # e.g. quay.io/org/repo@sha256:...
    local registry="${ref%%/*}"    # quay.io
    local rest="${ref#*/}"         # org/repo@sha256:...
    local repo="${rest%@*}"        # org/repo
    local digest="${ref#*@}"       # sha256:...

    local labels url rev
    labels="$(_image_labels_json "$registry" "$repo" "$digest")" || return 1
    url="$(printf '%s' "$labels" | jq -r '."org.opencontainers.image.source" // ."vcs-url" // empty')"
    rev="$(printf '%s' "$labels" | jq -r '."org.opencontainers.image.revision" // ."vcs-ref" // empty')"
    [[ -n "$url" && -n "$rev" ]] || return 1
    printf '%s\t%s' "$url" "$rev"
}

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

[[ -d "$tekton_dir" ]] || die "tekton dir not found: $tekton_dir"

if [[ -z "$snapshot_name" ]]; then
    snapshot_name="${application}-override-$(date +%Y%m%d-%H%M%S)"
fi

########################################
# 1. Map image-name -> component / quay repo (offline, from .tekton push files)
########################################
# CSV relatedImages are pinned to registry.redhat.io/<ns>/<image-name>@<digest>.
# The Snapshot must reference the quay.io build repo instead; both share the
# same trailing <image-name>, so we key the mapping on that name.
declare -A imgname_to_component
declare -A imgname_to_quaybase
declare -A component_context
declare -A component_dockerfile
shopt -s nullglob
push_files=("$tekton_dir"/*-push.yaml)
shopt -u nullglob
[[ ${#push_files[@]} -gt 0 ]] || die "no *-push.yaml files found in $tekton_dir"

# Read the value of a top-level spec.params entry by name from a PipelineRun.
# Only .spec.params is queried (not .spec.pipelineSpec.params), so parameter
# definitions with defaults are never picked up by mistake.
push_param() {
    NAME="$2" yq '.spec.params[] | select(.name == strenv(NAME)) | .value // ""' "$1" 2>/dev/null | head -1
}

for f in "${push_files[@]}"; do
    comp=$(yq '.metadata.labels."appstudio.openshift.io/component" // ""' "$f" 2>/dev/null)
    img=$(push_param "$f" output-image)
    [[ -z "$comp" || -z "$img" ]] && continue
    quaybase="${img%%@*}"        # strip @digest if present
    quaybase="${quaybase%%:*}"   # strip :tag (e.g. :{{revision}})
    imgname="${quaybase##*/}"    # last path segment (e.g. thanos-rhel9)
    imgname_to_component["$imgname"]="$comp"
    imgname_to_quaybase["$imgname"]="$quaybase"

    # path-context / dockerfile params populate spec.components[].source.git to
    # match Konflux-generated Snapshots. Only literal values are useful; skip
    # $(params.*) references.
    ctx=$(push_param "$f" path-context)
    dockerfile=$(push_param "$f" dockerfile)
    [[ "$ctx" == \$* ]] && ctx=""
    [[ "$dockerfile" == \$* ]] && dockerfile=""
    # Konflux records the context as "./" rather than "."
    [[ -z "$ctx" || "$ctx" == "." ]] && ctx="./"
    component_context["$comp"]="$ctx"
    component_dockerfile["$comp"]="$dockerfile"
done

[[ ${#imgname_to_component[@]} -gt 0 ]] || die "could not derive any component mappings from $tekton_dir"

########################################
# 2. Determine the bundle image (discover from cluster unless provided)
########################################
eff_ns="${namespace:-$(oc project -q 2>/dev/null || true)}"

if [[ -z "$bundle_image" ]]; then
    [[ -n "$eff_ns" ]] || die "no namespace given (-n) and no current oc context; cannot discover bundle image"
    log "Discovering bundle image from Component/$bundle_component in namespace $eff_ns"
    bundle_image=$(oc get component "$bundle_component" -n "$eff_ns" \
        -o jsonpath='{.status.lastPromotedImage}' 2>/dev/null || true)
    [[ -n "$bundle_image" ]] || die "could not read .status.lastPromotedImage from Component/$bundle_component in $eff_ns (pass --bundle-image to override)"
fi
[[ "$bundle_image" == *@sha256:* ]] || die "bundle image must be pinned by digest (repo@sha256:...): $bundle_image"
log "Bundle image: $bundle_image"

########################################
# 3. Extract the bundle CSV and read its relatedImages
########################################
tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

log "Extracting bundle CSV with 'oc image extract'"
oc image extract "$bundle_image" --path="/:$tmp_dir" --confirm >/dev/null 2>&1 \
    || die "failed to extract bundle image: $bundle_image"

csv_file="$(find "$tmp_dir/manifests" -name '*.clusterserviceversion.yaml' 2>/dev/null | head -1)"
[[ -n "$csv_file" && -f "$csv_file" ]] || die "no ClusterServiceVersion found in bundle manifests"
log "CSV: $(basename "$csv_file")"

mapfile -t related_images < <(yq '.spec.relatedImages[].image' "$csv_file" 2>/dev/null | grep -E '@sha256:' | sort -u)
[[ ${#related_images[@]} -gt 0 ]] || die "no relatedImages with digests found in the bundle CSV"
log "Found ${#related_images[@]} relatedImage(s) in the bundle CSV"

########################################
# 4. Cross-check the bundle's operand digests against render_templates
########################################
declare -A rt_digest_by_name
if [[ -f "$render_templates" ]]; then
    while read -r ref; do
        [[ -z "$ref" ]] && continue
        name="${ref%@*}"; name="${name##*/}"
        rt_digest_by_name["$name"]="${ref#*@}"
    done < <(grep -oE 'quay\.io/[^"[:space:]]+@sha256:[a-f0-9]+' "$render_templates" | sort -u)
else
    log "WARN: render_templates not found ($render_templates); skipping cross-check"
fi

########################################
# 5. Build the component list from the bundle's relatedImages (+ the bundle)
########################################
# Components accumulated as newline-delimited JSON (one object per line).
components_ndjson=""
skipped=0
unresolved_source=0
diverged=0

add_entry() {
    local comp="$1" ref="$2" ctx="$3" dockerfile="$4"
    local url="" rev="" src
    if src="$(resolve_git_source "$ref")"; then
        url="${src%%	*}"
        rev="${src#*	}"
    else
        log "ERROR: could not read git source (url/revision) labels for $ref"
        unresolved_source=$((unresolved_source + 1))
    fi
    components_ndjson+="$(jq -cn \
        --arg name "$comp" --arg image "$ref" \
        --arg url "$url" --arg revision "$rev" \
        --arg context "$ctx" --arg dockerfile "$dockerfile" \
        '{name: $name, containerImage: $image,
          source: {git: ({url: $url, revision: $revision}
            + (if $context != "" then {context: $context} else {} end)
            + (if $dockerfile != "" then {dockerfileUrl: $dockerfile} else {} end))}}')"$'\n'
    log "  + $comp -> $ref (revision: ${rev:-<none>})"
}

for img in "${related_images[@]}"; do
    digest="${img#*@}"
    name="${img%@*}"; name="${name##*/}"   # image name, e.g. thanos-rhel9
    comp="${imgname_to_component[$name]:-}"
    quaybase="${imgname_to_quaybase[$name]:-}"
    if [[ -z "$comp" || -z "$quaybase" ]]; then
        log "WARN: relatedImage '$name' has no .tekton component - skipping (assumed pre-released/external: $img)"
        skipped=$((skipped + 1))
        continue
    fi

    # Cross-check against render_templates (bundle remains source of truth).
    rt="${rt_digest_by_name[$name]:-}"
    if [[ -n "$rt" && "$rt" != "$digest" ]]; then
        log "WARN: $name digest differs from render_templates (bundle=$digest render_templates=$rt)"
        diverged=$((diverged + 1))
    fi

    add_entry "$comp" "${quaybase}@${digest}" \
        "${component_context[$comp]:-./}" "${component_dockerfile[$comp]:-}"
done

# Always include the bundle itself so the Snapshot ships it alongside the
# operands it references.
add_entry "$bundle_component" "$bundle_image" \
    "${component_context[$bundle_component]:-./}" \
    "${component_dockerfile[$bundle_component]:-}"

[[ -n "$components_ndjson" ]] || die "no components resolved; nothing to write"

if [[ "$unresolved_source" -gt 0 ]]; then
    die "could not resolve the git source for $unresolved_source image(s); the resulting Snapshot would fail the release-time Conforma check (slsa_source_correlated.source_code_reference_provided). Ensure the images are pullable and carry org.opencontainers.image.source/revision labels."
fi

########################################
# 6. Emit the override Snapshot YAML
########################################
# Build the Snapshot as JSON (components sorted by name for deterministic
# output) and transcode to YAML with yq.
emit() {
    local components
    components="$(printf '%s' "$components_ndjson" | jq -s 'sort_by(.name)')"
    jq -n \
        --arg name "$snapshot_name" \
        --arg namespace "$namespace" \
        --arg application "$application" \
        --argjson components "$components" \
        '{apiVersion: "appstudio.redhat.com/v1alpha1",
          kind: "Snapshot",
          metadata: ({name: $name}
              + (if $namespace != "" then {namespace: $namespace} else {} end)
              + {labels: {"test.appstudio.openshift.io/type": "override"}}),
          spec: {application: $application, components: $components}}' \
        | yq -p=json -o=yaml
}

if [[ -n "$output" ]]; then
    emit > "$output"
    log "Wrote override Snapshot to $output"
    log "Apply with: kubectl create -f $output ${namespace:+-n $namespace}"
else
    emit
fi

if [[ "$skipped" -gt 0 ]]; then
    log "NOTE: $skipped relatedImage(s) had no matching component and were skipped"
fi
if [[ "$diverged" -gt 0 ]]; then
    log "NOTE: $diverged operand digest(s) diverged from render_templates; the bundle CSV was used as the source of truth"
fi
