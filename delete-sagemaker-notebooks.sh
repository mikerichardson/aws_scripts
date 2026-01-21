#!/usr/bin/env bash

# Script to search and delete Amazon SageMaker Notebook instances across all opt-in regions
# Uses AWS CLI to manage SageMaker notebooks

set -e

## PREREQUISITES CHECK

# `exists` for commands
exists() {
	command -v "$1" >/dev/null 2>&1
}

# is AWS CLI installed?
if ! exists aws ; then
	printf "\n******************************************************************************************************************************\n\
This script requires the AWS CLI. See the details here: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html\n\
******************************************************************************************************************************\n\n"
	exit 1
fi

# Check if AWS credentials are configured
if ! aws sts get-caller-identity &>/dev/null; then
	echo
	echo "ERROR: AWS credentials are not configured or are invalid."
	echo "Please configure your credentials using 'aws configure' or ensure your AWS environment variables are set."
	echo
	exit 1
fi

echo "==========================================="
echo "SageMaker Notebook Instances Deletion Tool"
echo "==========================================="
echo

# Get AWS account information
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
echo "Running as: $USER_ARN"
echo "Account ID: $ACCOUNT_ID"
echo

# Function to get all regions (including opt-in regions)
get_all_regions() {
	aws ec2 describe-regions --all-regions --query "Regions[].RegionName" --output text
}

# Function to list SageMaker notebook instances in a region
list_notebooks_in_region() {
	local region=$1
	aws sagemaker list-notebook-instances --region "$region" --query "NotebookInstances[].NotebookInstanceName" --output text 2>/dev/null || echo ""
}

# Function to get notebook instance status
get_notebook_status() {
	local region=$1
	local notebook_name=$2
	aws sagemaker describe-notebook-instance --region "$region" --notebook-instance-name "$notebook_name" --query "NotebookInstanceStatus" --output text 2>/dev/null || echo "Unknown"
}

# Function to stop a notebook instance
stop_notebook() {
	local region=$1
	local notebook_name=$2
	echo "  → Stopping notebook instance: $notebook_name"
	aws sagemaker stop-notebook-instance --region "$region" --notebook-instance-name "$notebook_name" 2>/dev/null

	# Wait for the notebook to stop (max 5 minutes)
	local max_wait=60  # 60 * 5 seconds = 5 minutes
	local count=0
	while [ $count -lt $max_wait ]; do
		local status=$(get_notebook_status "$region" "$notebook_name")
		if [ "$status" = "Stopped" ]; then
			echo "  ✓ Notebook stopped: $notebook_name"
			return 0
		elif [ "$status" = "Failed" ]; then
			echo "  ✗ Notebook failed to stop: $notebook_name"
			return 1
		fi
		sleep 5
		count=$((count + 1))
		if [ $((count % 6)) -eq 0 ]; then
			echo "    (Still waiting for $notebook_name to stop... status: $status)"
		fi
	done
	echo "  ⚠ Timeout waiting for notebook to stop: $notebook_name"
	return 1
}

# Function to delete a notebook instance
delete_notebook() {
	local region=$1
	local notebook_name=$2
	echo "  → Deleting notebook instance: $notebook_name"
	if aws sagemaker delete-notebook-instance --region "$region" --notebook-instance-name "$notebook_name" 2>/dev/null; then
		echo "  ✓ Notebook deleted: $notebook_name"
		return 0
	else
		echo "  ✗ Failed to delete notebook: $notebook_name"
		return 1
	fi
}

# Main execution
echo "Retrieving all AWS regions (including opt-in regions)..."
REGIONS=$(get_all_regions)

if [ -z "$REGIONS" ]; then
	echo "ERROR: Could not retrieve AWS regions. Please check your AWS CLI configuration."
	exit 1
fi

REGION_COUNT=$(echo "$REGIONS" | wc -w)
echo "Found $REGION_COUNT regions to scan"
echo

# Track statistics
TOTAL_NOTEBOOKS=0
DELETED_NOTEBOOKS=0
FAILED_DELETIONS=0

# Scan each region
for region in $REGIONS; do
	echo "Scanning region: $region"

	# List notebooks in the region
	notebooks=$(list_notebooks_in_region "$region")

	if [ -z "$notebooks" ]; then
		echo "  No notebook instances found in $region"
		echo
		continue
	fi

	# Convert to array
	notebook_array=($notebooks)
	notebook_count=${#notebook_array[@]}
	TOTAL_NOTEBOOKS=$((TOTAL_NOTEBOOKS + notebook_count))

	echo "  Found $notebook_count notebook instance(s) in $region"

	# Process each notebook
	for notebook in $notebook_array; do
		echo "  Processing: $notebook"

		# Get current status
		status=$(get_notebook_status "$region" "$notebook")
		echo "    Current status: $status"

		# Stop the notebook if it's not already stopped
		if [ "$status" != "Stopped" ] && [ "$status" != "Stopping" ]; then
			if ! stop_notebook "$region" "$notebook"; then
				echo "  ⚠ Skipping deletion due to stop failure: $notebook"
				FAILED_DELETIONS=$((FAILED_DELETIONS + 1))
				continue
			fi
		elif [ "$status" = "Stopping" ]; then
			echo "  → Notebook is already stopping, waiting for it to stop..."
			# Wait for it to finish stopping
			local max_wait=60
			local count=0
			while [ $count -lt $max_wait ]; do
				status=$(get_notebook_status "$region" "$notebook")
				if [ "$status" = "Stopped" ]; then
					echo "  ✓ Notebook stopped: $notebook"
					break
				fi
				sleep 5
				count=$((count + 1))
			done
		else
			echo "  ✓ Notebook already stopped: $notebook"
		fi

		# Delete the notebook
		if delete_notebook "$region" "$notebook"; then
			DELETED_NOTEBOOKS=$((DELETED_NOTEBOOKS + 1))
		else
			FAILED_DELETIONS=$((FAILED_DELETIONS + 1))
		fi
	done

	echo
done

# Summary
echo "==========================================="
echo "Deletion Summary"
echo "==========================================="
echo "Total notebook instances found: $TOTAL_NOTEBOOKS"
echo "Successfully deleted: $DELETED_NOTEBOOKS"
echo "Failed deletions: $FAILED_DELETIONS"
echo "==========================================="
echo

if [ $TOTAL_NOTEBOOKS -eq 0 ]; then
	echo "No SageMaker notebook instances were found in any region."
elif [ $DELETED_NOTEBOOKS -eq $TOTAL_NOTEBOOKS ]; then
	echo "All notebook instances were successfully deleted!"
	exit 0
elif [ $DELETED_NOTEBOOKS -gt 0 ]; then
	echo "Some notebook instances were deleted, but there were failures."
	exit 1
else
	echo "No notebook instances could be deleted."
	exit 1
fi
