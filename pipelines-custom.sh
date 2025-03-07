branch="release-1.1"
for file in "$@"
do
    echo "Processing file $file"
    component="${file%-pu*.yaml}"
    action=$(basename `expr "$file" : '.*\(pu.*\.yaml\)'` .yaml | tr - _)
    dockerfile=$(yq '.spec.params[] | select(.name == "dockerfile").value' "$file")
    src="$(grep COPY "$file" | head -n1 | awk '{print $2}'| cut -d'/' -f1)"
    export trigger="event == \"$action\" && target_branch == \"$branch\" &&
        (\".tekton/$component-pull-request.yaml\".pathChanged() ||
        \".tekton/$component-push.yaml\".pathChanged() ||
        \"$dockerfile\".pathChanged() ||
        \"$src\".pathChanged())"
    yq -i '.metadata.annotations += {"build.appstudio.openshift.io/build-nudge-files": "bundle-patches/render_templates"}' "$file"
    yq -i '.metadata.annotations += {"pipelinesascode.tekton.dev/on-cel-expression": strenv(trigger)}' "$file"
    yq -i '(.spec.params[] | select(.name == "build-platforms").value) += ["linux/arm64","linux/ppc64le","linux/s390x"]' "$file"
    yq -i '.spec.params += [{"name": "build-source-image", "value": "true"}]' "$file"
done
