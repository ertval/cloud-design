# ==============================================================================
# k8s_doc.awk -- flatten multi-document Kubernetes YAML into one TSV line per
# document, keyed by dotted KEY PATH, so that a PodDisruptionBudget can be
# compared against the workload it actually selects and a livenessProbe can be
# compared against the readinessProbe next to it.
# ==============================================================================
#
# WHY THIS EXISTS
#   `grep -c '^kind: PodDisruptionBudget' manifests/*.yaml` counts OBJECTS. It
#   cannot tell whether a PDB protects anything, and it cannot tell that a
#   StatefulSet has none at all. Setting every `maxUnavailable` to 100 left the
#   audit green, while the shipped manifests were already vacuous: every
#   workload declares `replicas: 1` and every PDB `maxUnavailable: 1`, which
#   together permit evicting the only pod.
#
#   Naive greps are wrong here for a second, independent reason: `maxUnavailable`
#   is a legal key in TWO places in these files -- `spec.maxUnavailable` on the
#   PDB and `spec.strategy.rollingUpdate.maxUnavailable` on the Deployment. A
#   grep for the word cannot tell them apart; a dotted key path can.
#
# OUTPUT (one line per YAML document, tab separated, 12 columns)
#   1 kind            6 spec.selector.matchLabels.app
#   2 metadata.name   7 livenessProbe httpGet path      ("-" if none)
#   3 spec.replicas   8 readinessProbe httpGet path     ("-" if none)
#   4 spec.maxUnavailable   9 livenessProbe present? (http|exec/tcp|-|present)
#   5 spec.minAvailable    10 readinessProbe present?
#                          11 (reserved)  12 source file
# Every unset field is emitted as "-" so the column count never shifts.
#
# HOW IT PARSES
#   Nesting is resolved from INDENTATION with a pop-until-lower-indent stack, so
#   `spec.strategy.rollingUpdate.maxUnavailable` can never be mistaken for
#   `spec.maxUnavailable`, and a comment containing the word "replicas:" can
#   never contribute a value. Sequence items (`- name: http`) carry no key we
#   need, but they DO keep `containers` on the stack, so the probe paths are
#   matched by SUFFIX (`...livenessProbe.httpGet.path`) rather than by an exact
#   dotted path that would vary with where the list item sat.
#
# CALLER
#   awk -f scripts/lib/k8s_doc.awk manifests/*.yaml
# ==============================================================================

function vv(k) { return (k in v && v[k] != "") ? v[k] : "-" }

function flush() {
  if (have_kind)
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\t%s\n", \
      v["kind"], v["metadata.name"], vv("spec.replicas"), vv("spec.maxUnavailable"), \
      vv("spec.minAvailable"), vv("spec.selector.matchLabels.app"), \
      vv("lpath"), vv("rpath"), seen_live, seen_ready, curfile
  delete v; have_kind = 0; seen_live = "-"; seen_ready = "-"
}

function val(s) {
  gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s)
  gsub(/^["'\'']/, "", s); gsub(/["'\'']$/, "", s)
  return s
}

BEGIN { nl = 0; curfile = ""; seen_live = "-"; seen_ready = "-" }

FNR == 1 { flush(); curfile = FILENAME }

/^---[ \t]*$/  { flush(); next }
/^[ \t]*#[ \t]*/ { next }
/^[ \t]*$/   { next }
/^[ ]*-[ \t]/ { next }

{
  line = $0
  # strip a trailing comment that is not inside a quoted scalar
  if (line !~ /["'\'']/) sub(/[ \t]+#.*$/, "", line)
  ci = match(line, /[^ ]/) - 1
  body = substr(line, ci + 1)
  if (body !~ /^[A-Za-z0-9_.\/-]+:/) next
  thiskey = body; sub(/:.*$/, "", thiskey)
  rest = body; sub(/^[^:]*:[ \t]*/, "", rest)

  while (nl > 0 && ind[nl] >= ci) { delete ind[nl]; delete key[nl]; nl-- }
  nl++; ind[nl] = ci; key[nl] = thiskey
  path = key[1]
  for (i = 2; i <= nl; i++) path = path "." key[i]

  if (path == "kind") { v["kind"] = val(rest); have_kind = 1 }
  else if (path == "metadata.name") v["metadata.name"] = val(rest)
  else if (path == "spec.replicas") v["spec.replicas"] = val(rest)
  else if (path == "spec.maxUnavailable") v["spec.maxUnavailable"] = val(rest)
  else if (path == "spec.minAvailable") v["spec.minAvailable"] = val(rest)
  else if (path == "spec.selector.matchLabels.app") v["spec.selector.matchLabels.app"] = val(rest)
  else if (path ~ /(^|\.)livenessProbe\.httpGet\.path$/)  { v["lpath"] = val(rest); seen_live = "http" }
  else if (path ~ /(^|\.)readinessProbe\.httpGet\.path$/) { v["rpath"] = val(rest); seen_ready = "http" }
  else if (path ~ /(^|\.)livenessProbe\.(exec\.command|tcpSocket\.port)$/)  { if (seen_live  == "-") seen_live  = "exec/tcp" }
  else if (path ~ /(^|\.)readinessProbe\.(exec\.command|tcpSocket\.port)$/) { if (seen_ready == "-") seen_ready = "exec/tcp" }
}

END { flush() }