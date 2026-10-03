# ==============================================================================
# hcl_sg_world_open.awk -- report every INGRESS security-group rule that admits
# 0.0.0.0/0 (or ::/0), named by the security group it is actually ATTACHED TO.
# ==============================================================================
#
# WHY THIS FILE EXISTS
#   The one-line idiom both audit scripts used to share was:
#
#     awk '/^resource .aws_security_group./{sg=$3} /0\.0\.0\.0\/0/{print sg}' \
#         security_groups.tf | grep -Ex 'db|mq'
#
#   `$3` is the RESOURCE LABEL, not the group a rule is attached to, and the
#   answer therefore depended on where in the file a rule happened to sit
#   rather than on what it was attached to. The rules in security_groups.tf are
#   standalone `aws_security_group_rule` resources; the awk printed the label of
#   whichever `aws_security_group` block it had most recently walked past. The
#   same world-open exposure written as a standalone rule could therefore PASS
#   while the identical exposure written as an inline `ingress { }` block
#   FAILED -- the check was defeatable by formatting alone.
#
# WHAT IT DOES INSTEAD
#   Real brace-balanced block parsing with a stack, so sibling blocks at the
#   same nesting depth no longer clobber one another, and the following are all
#   understood:
#
#     1. inline   resource "aws_security_group" "db" { ingress { cidr_blocks =
#                ["0.0.0.0/0"] } }
#     2. standalone resource "aws_security_group_rule" "db_ingress" { type =
#                "ingress"; cidr_blocks = ["0.0.0.0/0"]; security_group_id =
#                aws_security_group.db.id }
#     3. modern   resource "aws_vpc_security_group_ingress_rule" "x" {
#                security_group_id = aws_security_group.db.id; cidr_ipv4 =
#                "0.0.0.0/0" }
#     4. a CIDR list split over several lines, and an `ingress { ... }` block
#        written on one line.
#
#   EGRESS rules that allow 0.0.0.0/0 are deliberately NOT reported: an egress
#   rule cannot make a resource reachable from the Internet, and every app SG
#   in this repo legitimately egresses to 0.0.0.0/0:443 for ECR/CloudWatch.
#
# OUTPUT (tab separated, one line per world-open ingress rule)
#   <security-group-label>\t<how-it-was-written>\t<file>:<line>
#
#   The label is `UNATTRIBUTED(<rule-label>)` if a world-open ingress rule
#   carries no resolvable `security_group_id`, because a rule we cannot
#   attribute is not evidence of a private data tier either.
#
# CALLER
#   awk -f scripts/lib/hcl_sg_world_open.awk terraform/*.tf
# ==============================================================================

# Strip comments without cutting inside a double-quoted string. Terraform
# descriptions routinely contain '#', '//' and '/' (URLs, ports, ISO dates), so
# a naive sub() would truncate real attribute lines.
function strip(s,   i, c, q, n, out) {
  n = length(s); q = 0; out = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q) { out = out c; if (c == "\"") q = 0; continue }
    if (c == "\"") { q = 1; out = out c; continue }
    if (c == "#") break
    if (c == "/" && substr(s, i + 1, 1) == "/") break
    out = out c
  }
  return out
}

# Attribute a world-open CIDR to the block that is innermost AT THAT POINT in
# the character scan. Doing this per line instead of per brace would miss
# `ingress { cidr_blocks = ["0.0.0.0/0"] }` written on a single line.
function mark(seg) {
  if (sp > 0 && (seg ~ /0\.0\.0\.0\/0/ || seg ~ /"::\/0"/)) push_world[sp] = 1
}

# The identifier immediately before a '{', trimmed. `ingress {` yields
# "ingress"; `tags = merge(a, {` yields "" and so can never be mistaken for a
# rule block.
function pre_of(line, upto,   s) {
  s = substr(line, 1, upto - 1)
  gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s)
  return s
}

function emit(sg, how, where) { printf "%s\t%s\t%s\n", sg, how, where }

function report(where) {
  if (rtype == "aws_security_group") {
    if (saw_inline_world) emit(rlabel, "inline-ingress", where)
  } else if (rtype == "aws_security_group_rule") {
    if (push_world[1] && rule_type == "ingress")
      emit(sgref == "" ? "UNATTRIBUTED(" rlabel ")" : sgref, "standalone-rule", where)
  } else if (rtype == "aws_vpc_security_group_ingress_rule") {
    if (push_world[1])
      emit(sgref == "" ? "UNATTRIBUTED(" rlabel ")" : sgref, "vpc-ingress-rule", where)
  }
}

BEGIN { sp = 0; rtype = ""; rlabel = ""; pending = 0; saw_inline_world = 0 }

{
  line = strip($0)
  if (line ~ /^[[:space:]]*$/) next

  # Resource header. `split` on '"' yields ["aws_sg", " ", "db", " {"], hence a[3].
  if (pending == 0 && line ~ /^[[:space:]]*resource[[:space:]]+"[^"]+"[[:space:]]+"[^"]+/) {
    t = line; sub(/^[[:space:]]*resource[[:space:]]+"/, "", t); split(t, a, "\"")
    rtype = a[1]; rlabel = a[3]; pending = 1
  }
  if (line ~ /security_group_id[[:space:]]*=[[:space:]]*aws_security_group\.[A-Za-z0-9_-]+\.id/ &&
      match(line, /aws_security_group\.[A-Za-z0-9_-]+\.id/)) {
    split(substr(line, RSTART, RLENGTH), b, "."); sgref = b[2]
  }
  if (line ~ /type[[:space:]]*=[[:space:]]*"ingress"/) rule_type = "ingress"
  if (line ~ /type[[:space:]]*=[[:space:]]*"egress"/)  rule_type = "egress"

  m = length(line); seg = ""
  for (i = 1; i <= m; i++) {
    c = substr(line, i, 1)
    if (c != "{" && c != "}") { seg = seg c; continue }
    mark(seg); seg = ""
    if (c == "{") {
      sp++
      if (sp == 1 && pending) { push_name[1] = rlabel; pending = 0 }
      else push_name[sp] = pre_of(line, i)
      push_world[sp] = 0
    } else {
      if (sp == 1) {
        report(FILENAME ":" FNR)
        delete push_name; delete push_world; sp = 0
        rtype = ""; rlabel = ""; sgref = ""; rule_type = ""
        pending = 0; saw_inline_world = 0
      }
      # An inline `ingress { }` is popped before the resource closes, so its
      # verdict has to be latched here rather than read back off the stack.
      if (sp > 1 && push_name[sp] == "ingress" && push_world[sp]) saw_inline_world = 1
      if (sp > 0) { delete push_name[sp]; delete push_world[sp]; sp-- }
    }
  }
  mark(seg)
}