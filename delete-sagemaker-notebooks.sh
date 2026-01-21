#!/usr/bin/env bash

# Script to search and delete Amazon SageMaker Notebook instances across all enabled regions
# Uses AWS CLI to manage SageMaker notebooks
# NOTE: This script assumes all notebook instances are already stopped

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

# Function to get only enabled regions (excludes non-opted-in regions)
get_enabled_regions() {
	aws ec2 describe-regions --all-regions --query "Regions[?OptInStatus=='opt-in-not-required' || OptInStatus=='opted-in'].RegionName" --output text
}

# Function to list SageMaker notebook instances in a region
list_notebooks_in_region() {
	local region=$1
	aws sagemaker list-notebook-instances --region "$region" --query "NotebookInstances[].NotebookInstanceName" --output text 2>/dev/null || echo ""
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
echo "Retrieving enabled AWS regions..."
REGIONS=$(get_enabled_regions)

if [ -z "$REGIONS" ]; then
	echo "ERROR: Could not retrieve AWS regions. Please check your AWS CLI configuration."
	exit 1
fi

REGION_COUNT=$(echo "$REGIONS" | wc -w)
echo "Found $REGION_COUNT enabled region(s) to scan"
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

		# Delete the notebook (assumes it's already stopped)
		if delete_notebook "$region" "$notebook"; then
			DELETED_NOTEBOOKS=$((DELETED_NOTEBOOKS + 1))
		else
			echo "  ⚠ Note: If deletion failed because the notebook is not stopped, stop it first and retry"
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
