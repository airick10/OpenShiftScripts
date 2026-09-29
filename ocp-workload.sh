#!/bin/bash

#===================================
# OpenShift Workload Standards Audit v1
# Read-only
#
# Requires:
# oc
# jq
#
# Purpose
#   Find common reliability, resource, security,
#   storage, networking, and lifecycle standards gaps
#   in application workloads.
# ===================================

WARN=0
PASS=0
INFO=0
INVESTIGATE=()

pass() {
	echo "[PASS] $1"
	((PASS++))
}

warn() {
	echo "[WARN] $1"
	((WARN++))
}

info() {
	echo "[INFO] $1"
	((INFO++))
}

# -------------------------------------------------------
# Namespace Filtering
# Excludes OpenShift/Kubernetes infrastructure namespace
# Add environment-specific infrastructure namespace here.
# -------------------------------------------------------

is_app_namespace() {
	case "$1" in
		openshift-*|kube-*|default)
			return 1
			;;
		*)
			return 0
			;;
	esac
}

# Build namespace list once.

APP_NAMESPACES=()

while read -r ns; do
	if is_app_namespace "$ns"; then
		APP_NAMESPACES+=("$ns")
	fi
done < <(oc get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

echo
echo "================================================="
echo " OPENSHIFT WORKLOAD STANDARDS Audit"
echo " $(date)"
echo "================================================="
echo

echo "Application namespaces: ${#APP_NAMESPACES[@]}"
echo

# ======================================================
# INVENTORY
# ======================================================

DEPLOYMENTS=0
STATEFULSETS=0
PODS=0

for ns in "${APP_NAMESPACES[@]}"; do

	d=$(oc get deployment -n "$ns" --no-headers 2>/dev/null | wc -l)
	s=$(oc get statefulset -n "$ns" --no-headers 2>/dev/null | wc -l)
	p=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
	
	((DEPLOYMENTS+=d))
	((STATEFULSETS+=s))
	((PODS+=p))
	
done

echo "Deployments:             $DEPLOYMENTS"
echo "Statefulsets:            $STATEFULSETS"
echo "Running/current pods:   $PODS"

# ======================================================
# RESOURCE MANAGEMENT
# ======================================================

echo "------------- RESOURCE MANAGEMENT ----------------"

NO_CPU_REQUEST=0
NO_MEM_REQUEST=0
NO_CPU_LIMIT=0
NO_MEM_LIMIT=0

for ns in "${APP_NAMESPACES[@]}"; do

	DATA=$(oc get deployment,statefulset -n "$ns" -o json 2>/dev/null)
	
	count=$(echo "$DATA" | jq '
	  [
		.items[] |
		.spec.template.spec.containers[]? | 
		select(.resources.requests.cpu == null)
	  ] | length
	')
	((NO_CPU_REQUEST+=count))
	
	count=$(echo "$DATA" | jq '
	  [
		.items[] |
		.spec.template.spec.containers[]? | 
		select(.resources.requests.memory == null)
	  ] | length
	')
	((NO_MEM_REQUEST+=count))
	
	count=$(echo "$DATA" | jq '
	  [
		.items[] |
		.spec.template.spec.containers[]? | 
		select(.resources.limits.cpu == null)
	  ] | length
	')
	((NO_CPU_LIMIT+=count))
	
	count=$(echo "$DATA" | jq '
	  [
		.items[] |
		.spec.template.spec.containers[]? | 
		select(.resources.limits.memory == null)
	  ] | length
	')
	((NO_MEM_LIMIT+=count))
	
done

if [[ "$NO_CPU_REQUEST" -eq 0 ]]; then
	pass "All containers define CPU requests"
else
	warn "$NO_CPU_REQUEST container(s) missing CPU requests"
	INVESTIGATE+=(
	  "Missing CPU requests|oc getdeployment,statefulset -A"
	)
fi

if [[ "$NO_MEM_REQUEST" -eq 0 ]]; then
	pass "All containers define memory requests"
else
	warn "$NO_MEM_REQUEST container(s) missing memory requests"
	INVESTIGATE+=(
	  "Missing memory requests|oc getdeployment,statefulset -A"
	)
fi

if [[ "$NO_CPU_LIMIT" -eq 0 ]]; then
	pass "All containers define CPU limits"
else
	warn "$NO_CPU_LIMIT container(s) missing CPU limits"
fi

if [[ "$NO_MEM_LIMIT" -eq 0 ]]; then
	pass "All containers define memory limits"
else
	warn "$NO_MEM_LIMIT container(s) missing memory limits"
fi

echo

# ==============================================
# HEALTH PROBES
# ==============================================

echo "---------- RELIABILITY ---------------------"

NO_READINESS=0
NO_LIVENESS=0

for ns in "${APP_NAMESPACES[@]}"; do

	DATA=$(oc get deployment,statefulset -n "$ns" -o json 2>/dev/null)
	
	count=$(echo "$DATA" | jq '
	  [
		.items[] |
		.spec.template.spec.containers[]? |
		select(.readinessProbe == null)
	  ] | length
	')
	((NO_READINESS+=count))
	
	count=$(echo "$DATA" | jq '
	  [
		.items[] |
		.spec.template.spec.containers[]? |
		select(.livenessProbe == null)
	  ] | length
	')
	((NO_LIVENESS+=count))
	
done

if [[ "$NO_READINESS" -eq 0 ]]; then
	pass "All workload containers define readiness probes"
else
	warn "$NO_READINESS container(s) missing readiness probes"
	
	INVESTIGATE+=(
	  "Missing readiness probes|oc get deployment,statefulset -A"
	)
fi

if [[ "$NO_LIVENESS" -eq 0 ]]; then
	pass "All workload containers define liveness probes"
else
	warn "$NO_LIVENESS container(s) missing liveness probes"
	
	INVESTIGATE+=(
	  "Missing liveness probes|oc get deployment,statefulset -A"
	)
fi

# --------------------------------------------------------
# Single Replica Deployments
# --------------------------------------------------------

SINGLE_REPLICA=0

for ns in "${APP_NAMESPACES[@]}"; do

	count=$(oc get deployments -n "$ns" -o json 2>/dev/null | jq '
      [
		.items[] |
		select((.spec.replicas // 1) == 1)
	  ] | length
	')
	
	((SINGLE_REPLICA+=count))

done

if [[ "$SINGLE_REPLICA" -eq 0 ]]; then
	pass "No single-replica Deployments"
else
	warn "$SINGLE_REPLICA Deployment(s) have only one replica"
	
	INVESTIGATE+=(
		"Single replica Deployments|oc get deployment -A"
	)
fi

# -----------------------------------------------
# PDBs Blocking Disruption
# -----------------------------------------------

ZERO_PDB=0

for ns in "${APP_NAMESPACES[@]}"; do

	count=$(oc get pdb -n "$ns" -o json 2>/dev/null | jq '
	  [
		.items[] |
		select(.status.disruptionsAllowed == 0)
	  ] | length
	')
	
	((ZERO_PDB+=count))
	
done

if [[ "$ZERO_PDB" -eq 0 ]]; then
	pass "No PDBs currently allow zero disruptions"
else
	warn "$ZERO_PDB PDB(s) currently allow zero disruptions"
	
	INVESTIGATE+=(
	  "PDB zero disruptions|oc get pdb -A"
	  "PDB zero disruptions|oc describe pdb <PDB> -n <NAMESPACE>"
	)
	
fi

echo

# =================================================
# CURRENT RUNTIME HEALTH
# =================================================

echo "------------- RUNTIME HEALTH -----------------"

HIGH_RESTARTS=0
OOMKILLS=0

for ns in "${APP_NAMESPACES[@]}"; do

	DATA=$(oc get pods -n "$ns" -o json 2>/dev/null)
	
	count=$(echo "$DATA" | jq '
	  [
		.items[] |
		.status.containerStatuses[]? |
		select(.restartCount >= 10)
	  ] | length
	')
	((HIGH_RESTARTS+=count))
	
	count=$(echo "$DATA" | jq '
	  [
		.items[] |
		.status.containerStatuses[]? |
		select(
		  .lastState.terminated.reason == "OOMKilled" or
		  .state.terminated.reason == "OOMKilled"
		  )
	  ] | length
	')
	((OOMKILLS+=count))
	
done

if [[ "$HIGH_RESTARTS" -eq 0 ]]; then
    pass "No containers have >=10 restarts"
else
	warn "$HIGH_RESTARTS container(s) have >=10 restarts"
	
	INVESTIGATE+=(
	  "High container restarts|oc get pods -A"
	  "High container restarts|oc describe pod <POD> -n <NAMESPACE>"
	  "High container restarts|oc logs <POD> -n <NAMESPACE> --previous"
	)

fi

if [[ "$OOMKILLS" -eq 0 ]]; then
	pass "No current containers show recent OOMKilled state"
else
	warn "$OOMKILLS container(s) show recent OOMKilled state"
	
	INVESTIGATE+=(
	  "OOMKilled containers|oc describe pod <POD> -n <NAMESPACE>"
	  "OOMKilled containers|oc logs <POD> -n <NAMESPACE> --previous"
	)
fi

echo 

# =====================================================
# SECURITY / NODE COUPLING
# =====================================================

echo "----------- SECURITY / NODE COUPLING -------------------"

PRIVILEGED=0
HOSTPATH=0
HOSTNETWORK=0

for ns in "${APP_NAMESPACES[@]}"; do

	DATA=$(oc get deployment,statefulset -n "$ns" -o json 2>/dev/null)
	
	count=$(echo "$DATA" | jq '
	  [
		.items[] |
		.spec.template.spec.containers[]? |
		select(.securityContext.privileged == true)
	  ] | length
	')
	((PRIVILEGED+=count))
	
	count=$(echo "$DATA" | jq '
	  [
		.items[] |
		select(
		  any(.spec.template.spec.volumes[]?;
			.hostPath != null)
		)
	  ] | length
	')
	((HOSTPATH+=count))
	
	count=$(echo "$DATA" | jq '
	  [
		.items[] |
		select(.spec.template.spec.hostNetwork == true)
	  ] | length
	')
	((HOSTNETWORK+=count))
	
done

if [[ "$PRIVILEGED" -eq 0 ]]; then
	pass "No application containers explicity privileged"
else
	warn "$PRIVILEGED application container(s) explicity privileged"
	
	INVESTIGATE+=(
		"Privileged workloads|oc adm policy who-can use scc/privileged"
	)
fi

if [[ "$HOSTPATH" -eq 0 ]]; then
	pass "No application workloads use hostPath"
else
	warn "$HOSTPATH workload(s) use hostPath"
fi

if [[ "$HOSTNETWORK" -eq 0 ]]; then
	pass "No application workloads use hostNetwork"
else
	warn "$HOSTNETWORK workload(s) use hostNetwork"
fi

echo

# =======================================================
# Storage
# =======================================================

echo "------------- STORAGE -----------------------"

DIRECT_NFS=0

for ns in "${APP_NAMESPACES[@]}"; do

	DATA=$(oc get deployment,statefulset -n "$ns" -o json 2>/dev/null)
	
	count=$(echo "$DATA" | jq '
	  [
		.items[] |
		select(
		  any(.spec.template.spec.volumes[]?;
			.nfs != null)
		)
	  ] | length
	')
	
	((DIRECT_NFS+=count))
	
done


if [[ "$DIRECT_NFS" -eq 0 ]]; then
	pass "No application workloads directly mount NFS"
else
	warn "$DIRECT_NFS workload(s) directly mount NFS"
	
	INVESTIGATE+=(
	  "Direct NFS workloads|oc get deployment,statefulset -A -o yaml"
	)
fi

echo 

# ==========================================
# IMAGE HYGIENE
# ==========================================

echo "----------------- IMAGE / LIFECYCLE ------------------"

LATEST_IMAGES=0

for ns in "${APP_NAMESPACES[@]}"; do
	
	DATA=$(oc get deployment,statefulset -n "$ns" -o json 2>/dev/null)
	
	count=$(echo "$DATA" | jq '
	  [
		.items[] |
		.spec.template.spec.containers[]? |
		select(
		  (.image | endswith(":latest")) or
		  ((.image | contains("@sha256:") | not) and
		    ((.image | split("/")[-1] | contains(":") | not))
		)
	  ] | length
	')
	
	((LATEST_IMAGES+=count))
	
done

if [[ "$LATEST_IMAGES" -eq 0 ]]; then
	pass "No obvious latest/untagged workload images"
else
	warn "$LATEST_IMAGES container(s) use latest or untagged images"
fi

# =================================================
# Failed Jobs
# =================================================

FAILED_JOBS=0

for ns in "${APP_NAMESPACES[@]}"; do
	count=$(oc get jobs -n "$ns" -o json 2>/dev/null | jq '
	  [
		.items[] |
		select((.status.failed // 0) > 0)
	  ] | length
	')
	
	((FAILED_JOBS+=count))
done

if [[ "$FAILED_JOBS" -eq 0 ]]; then
	pass "No failed jobs"
else
	warn "$FAILED_JOBS Job(s) report failures"
	
	INVESTIGATE+=(
	  "Failed Jobs|oc get jobs -A"
	  "Failed Jobs|oc describe job <JOB> -n <NAMESPACE>"
	)

fi

echo

# ================================================
# NAMESPACE GUARDRAILS
# ================================================

echo "---------------- NAMESPACE GUARDRAILS ----------------"

NO_QUOTA=0
NO_LIMITRANGE=0
NO_NETPOL=0

for ns in "${APP_NAMESPACES[@]}"; do

	# Only count namespace that actually contain workloads.
	workload_count=$(
	  oc get deployment,statefulset -n "$ns" --no-headers 2>/dev/null | wc -l)
	  
	if [[ "$workload_count" -eq 0 ]]; then
		continue
	fi
	
	count=$(oc get resourcequota -n "$ns" --no-headers 2>/dev/null | wc -l)
	
	if [[ "$count" -eq 0 ]]; then
		((NO_QUOTA++))
	fi
	
	count=$(oc get limitrange -n "$ns" --no-headers 2>/dev/null | wc -l)
	
	if [[ "$count" -eq 0 ]]; then
		((NO_LIMITRANGE++))
	fi
	
	count=$(oc get networkpolicy -n "$ns" --no-headers 2>/dev/null | wc -l)
	
	if [[ "$count" -eq 0 ]]; then
		((NO_NETPOL++))
	fi

done

if [[ "$NO_QUOTA" -eq 0 ]]; then
	pass "All workload namespaces have ResourceQuota"
else
	info "$NO_QUOTA workload namespace(s) have no ResourceQuota"
fi

if [[ "$NO_LIMITRANGE" -eq 0 ]]; then
	pass "All workload namespaces have LimitRange"
else
	info "$NO_LIMITRANGE workload namespace(s) have no LimitRange"
fi

if [[ "$NO_NETPOL" -eq 0 ]]; then
	pass "All workload namespaces contain NetworkPolicy"
else
	warn "$NO_NETPOL workload namespace(s) contain no NetworkPolicy"
	
	INVESTIGATE+=(
	  "Namespaces without NetworkPolicy|oc get networkpolicy -A"
	)
fi

# ================================================
# SUMMARY
# ================================================

echo
echo "=================================================="
echo " SUMMARY"
echo "=================================================="
echo " PASS : $PASS"
echo " WARN : $WARN"
echo " INFO : $INFO"
echo "=================================================="

# ===================================================
# INVESTIGATION COMMANDS
# ===================================================

if [[ ${#INVESTIGATE[@]} -gt 0 ]]; then

	echo 
	echo "================================================"
	echo " INVESTIGATE"
	echo "================================================"
	
	LAST_REASON=""
	
	for ENTRY in "${INVESTIGATE[@]}"; do
	
		REASON="${ENTRY%%|*}"
		COMMAND="${ENTRY#*|}"
		
		if [[ "$REASON" != "$LAST_REASON" ]]; then
			echo
			echo "$REASON:"
			LAST_REASON="$REASON"
			
		fi
		
		echo "    $COMMAND"
		
	done
	
	echo
	echo "============================================="
	
fi