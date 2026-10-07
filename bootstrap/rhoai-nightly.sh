#!/bin/bash
set -e
# Provision the cluster-side prerequisites for the RHOAI nightly install:
# the quay.io/rhoai registry mirror (ROSA image-mirror) and pull secret.
#
# These cannot be GitOps-managed: the mirror is a ROSA/OCM-level resource and
# the secret comes from credentials supplied at runtime. Invoked by
# bootstrap.sh; may also be run standalone to (re)apply on an existing cluster.
#
# Required environment:
#   RHOAI_QUAY_PULL_SECRET - base64 "username:password" for quay.io/rhoai

# Preflight: the rosa image-mirror call goes through OCM, so verify
# connectivity first.
if ! command -v ocm >/dev/null 2>&1; then
  echo "ERROR: 'ocm' is not installed or not in PATH." >&2
  exit 1
fi
if ! ocm whoami >/dev/null 2>&1; then
  echo "ERROR: Not authenticated with OCM." >&2
  echo "Please log in by running:" >&2
  echo "  ocm login --url production --use-auth-code" >&2
  exit 1
fi

# base64 "username:password" for quay.io/rhoai
: "${RHOAI_QUAY_PULL_SECRET:?RHOAI_QUAY_PULL_SECRET must be set to a base64 'username:password' for quay.io/rhoai}"

# ROSA cluster name is the first DNS label after 'api.' in the API server URL
CLUSTER_NAME=$(oc whoami --show-server | sed -E 's#^https?://api\.([^.]+)\..*#\1#')
echo "Setting up quay.io/rhoai mirror and pull secret on cluster '${CLUSTER_NAME}'..."

# Mirror registry.redhat.io/rhoai -> quay.io/rhoai so the nightly digests
# (referenced via registry.redhat.io) resolve to quay.io.
set +e
MIRROR_OUT=$(rosa create image-mirror \
  --source=registry.redhat.io/rhoai \
  --mirrors=quay.io/rhoai \
  --cluster="${CLUSTER_NAME}" 2>&1)
MIRROR_RC=$?
set -e
if [ ${MIRROR_RC} -ne 0 ] && ! grep -q "already exists" <<<"${MIRROR_OUT}"; then
  echo "ERROR: failed to create image mirror:" >&2
  echo "${MIRROR_OUT}" >&2
  exit 1
fi
echo "Image mirror ensured."

# Wait for the mirror to show up as an ImageDigestMirrorSet on the cluster
# (ROSA reconciles it asynchronously; operators won't pull until it lands).
echo "Waiting for quay.io/rhoai to appear in imagedigestmirrorsets..."
MIRROR_FOUND=
for _ in $(seq 1 60); do
  if oc get imagedigestmirrorsets.config.openshift.io -o json 2>/dev/null | grep -q '"quay.io/rhoai"'; then
    MIRROR_FOUND=1
    break
  fi
  sleep 10
done
if [ -z "${MIRROR_FOUND}" ]; then
  echo "ERROR: timed out waiting for quay.io/rhoai in imagedigestmirrorsets." >&2
  exit 1
fi
echo "Mirror verified."

# Merge the quay.io/rhoai credentials into the cluster-wide pull secret via
# the additional-pull-secret mechanism (kube-system).
DOCKERCONFIGJSON=$(jq -n --arg auth "${RHOAI_QUAY_PULL_SECRET}" \
  '{auths: {"quay.io/rhoai": {auth: $auth}}}' | base64 -w0)
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: additional-pull-secret
  namespace: kube-system
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${DOCKERCONFIGJSON}
EOF
echo "Pull secret 'additional-pull-secret' ensured in kube-system."
