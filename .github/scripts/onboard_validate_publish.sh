#! /bin/bash

#
# this function generates values that will be used as deployment values during the validation of the offering version.
function generateValidationValues() {
    local validationValues=$1

    # we only need to do this once.
    FILE=$1
    if [ -f "$FILE" ]; then
        return
    fi

    # generate an ssh key that can be used as a validation value. overwrite file if already there. 
    ssh-keygen -f ./id_rsa -t rsa -N '' <<<y

    SSH_KEY=$(cat ./id_rsa.pub)
    SSH_PRIVATE_KEY="$(cat ./id_rsa)"

    # use a unique prefix string value 
    SUFFIX="$(date +%m%d-%H-%M)"
    PREFIX="val-${SUFFIX}"

    # format offering validation values into json format.  the json keys used here match the names of the defined deployment variables that are already 
    # defined on the offering.  Manually import one version, a one time step, to initially setup deployment variables and set other metadata using the UI.
    jq -n --arg IBMCLOUD_API_KEY "$IBMCLOUD_API_KEY" --arg PREFIX "$PREFIX" --arg SSH_KEY "$SSH_KEY" --arg SSH_PRIVATE_KEY "$SSH_PRIVATE_KEY" '{ "ibmcloud_api_key": $IBMCLOUD_API_KEY, "prefix": $PREFIX, "ssh_key": $SSH_KEY, "ssh_private_key": $SSH_PRIVATE_KEY }' > "$validationValues"
}

#
# this function imports a version of an existing offering into a catalog.
function importVersionToCatalog() {
    local catalogName=$1
    local offeringName=$2
    local version=$3
    local variation=$4
    local formatKind=$5

    local tarballURL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/archive/refs/tags/${version}.tar.gz"

    # import the version into the catalog.  the offering must already exist in the catalog - just adding a version here.
    ibmcloud catalog offering import-version --zipurl "$tarballURL" --target-version "$version" --catalog "$catalogName" --offering "$offeringName" --include-config --variation "$variation" --format-kind "$formatKind" || ret=$?
    if [[ ret -ne 0 ]]; then
        exit 1
    fi    
}

# 
# this function querys the catalog and retrieves the version locator for a version.
function getVersionLocator() {
    local catalogName=$1
    local offeringName=$2
    local version=$3
    local formatKind=$4
    local versionLocator

    # get the catalog version locator for an offering version
    ibmcloud catalog offering get --catalog "$catalogName" --offering "$offeringName" --output json > offering.json
    versionLocator=$(jq -r --arg version "$version" --arg format_kind "$formatKind" '.kinds[] | select(.format_kind==$format_kind).versions[] | select(.version==$version).version_locator' < offering.json)

    echo "${versionLocator}"
}

#
# this function calls the schematics service and validates a verion of the offering.
function validateVersion() {
    local catalogName=$1
    local offeringName=$2
    local version=$3
    local formatKind=$4
    local resourceGroup=$5

    local versionLocator
    local validationStatus
    local validationValues="validation-values.json"
    local timeOut=10800         # 3 hours - sufficiently large.  will not run this long.    

    # generate values for the deployment variables defined for this version of the offering
    generateValidationValues "${validationValues}"
    versionLocator=$(getVersionLocator "$catalogName" "$offeringName" "$version" "$formatKind")
    echo "the version locator is $versionLocator"

    # need to target a resource group - deployed resources will be in this resource group
    ibmcloud target -g "${resourceGroup}"

    # refresh our login token since validation can run a little while
    ibmcloud catalog netrc

    # invoke schematics service to validate the version.  this will wait for that operation to complete.
    ibmcloud catalog offering version validate --vl "${versionLocator}" --override-values "${validationValues}" --timeout $timeOut || ret=$?    
    
    # if the validate failed, try to run an apply operation again since clouds can have intermitant issues.
    if [[ ret -ne 0 ]]; then
        if [ "$formatKind" = "terraform" ]
            then retryValidateWorkspace "$catalogName" "$offeringName" "$version"
            else retryValidateBlueprint "$catalogName" "$offeringName" "$version"
        fi
        # determine if the offering version validated after the retry
        validationStatus=$(ibmcloud catalog offering version validate-status -vl "${versionLocator}" --output json | jq -r '.state')
        if [ "$validationStatus" != valid ]; then
            echo "failed to validate after retry"
            exit 1
        fi
    fi
}

#
# this function retries a validation for a terraform workspace
function retryValidateWorkspace() {
    local catalogName=$1
    local offeringName=$2
    local version=$3

    local validateStatus
    local workspaceId

    workspaceId=$(getWorkspaceId "$catalogName" "$offeringName" "$version")
    echo "retrying apply for workspace ${workspaceId}"
    ibmcloud schematics apply --id "${workspaceId}" --force 

    # wait 15 seconds between each query up to a limit of 60 minutes which is 240 attempts
    attempts=0
    validateStatus="INPROGRESS"
    # quit when the max attempts have been made or if the workspace status changes
    while [[ $attempts -le 240 ]] && [ "$validateStatus" = "INPROGRESS" ]
    do
        sleep 15
        validateStatus=$(getWorkspaceStatus "$workspaceId")
        echo "retrying validation status is $validateStatus"
        attempts=$((attempts+1))
    done
}

#
# this function retries a validation for a blueprint 
function retryValidateBlueprint() {
    local catalogName=$1
    local offeringName=$2
    local version=$3

    local validateStatus
    local blueprintId

    blueprintId=$(getBlueprintId "$catalogName" "$offeringName" "$version")
    echo "retrying apply for blueprint ${blueprintId}"
    ibmcloud schematics blueprint apply -i "${blueprintId}"

    # wait 15 seconds between each query up to a limit of 60 minutes which is 240 attempts
    attempts=0
    validateStatus="RUN_APPLY_INPROGRESS"
    # quit when the max attempts have been made or if the workspace status changes
    while [[ $attempts -le 240 ]] && [ "$validateStatus" = "RUN_APPLY_INPROGRESS" ]
    do
        sleep 15
        validateStatus=$(getBlueprintStatus "${blueprintId}")
        echo "retrying validation status is $validateStatus"
        attempts=$((attempts+1))
    done
}

#
# this function invokes a CRA scan on a validated version.
function scanVersion() {
    local catalogName=$1
    local offeringName=$2
    local version=$3
    local formatKind=$4
    local scanFlag=$5

    local versionLocator

    versionLocator=$(getVersionLocator "$catalogName" "$offeringName" "$version" "$formatKind")

    if [ "$scanFlag" = SCAN ]; then
        ibmcloud catalog offering version cra --vl "${versionLocator}"
    else
        echo "CRA scan skipped"
    fi    
}

#
# this function marks a validated version as 'Ready'
function publishVersion() {
    local catalogName=$1
    local offeringName=$2
    local version=$3
    local formatKind=$4

    local versionLocator

    versionLocator=$(getVersionLocator "$catalogName" "$offeringName" "$version" "$formatKind")
    ibmcloud catalog offering ready --vl "${versionLocator}"
}


# ------------------------------------------------------------------------------------
#  main
# ------------------------------------------------------------------------------------

CATALOG_NAME=$1
OFFERING_NAME=$2
VERSION=$3
VARIATION=$4
RESOURCE_GROUP=$5
FORMAT_KIND=$6
CRA_SCAN=$7

echo "CatalogName: $CATALOG_NAME"
echo "OfferingName: $OFFERING_NAME"
echo "Version: $VERSION"
echo "Variation: $VARIATION"
echo "ResourceGroup: $RESOURCE_GROUP"
echo "FormatKind: $FORMAT_KIND"

source ./.github/scripts/common-functions.sh

# steps
importVersionToCatalog "$CATALOG_NAME" "$OFFERING_NAME" "$VERSION" "$VARIATION" "$FORMAT_KIND"
validateVersion "$CATALOG_NAME" "$OFFERING_NAME" "$VERSION" "$FORMAT_KIND" "$RESOURCE_GROUP"
scanVersion "$CATALOG_NAME" "$OFFERING_NAME" "$VERSION" "$FORMAT_KIND" "$CRA_SCAN"
publishVersion "$CATALOG_NAME" "$OFFERING_NAME" "$VERSION" "$FORMAT_KIND"