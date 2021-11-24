#!/bin/sh
# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

PROJECT_ID=$(gcloud config get-value project)
gcloud builds submit --tag "gcr.io/$PROJECT_ID/apigee-target" --project "$PROJECT_ID"

gcloud run deploy apigee-target-demo \
         --image="gcr.io/$(gcloud config get-value project)/apigee-target" \
         --platform=managed \
         --region=us-west1 \
         --no-allow-unauthenticated --project "$PROJECT_ID"

SA_EMAIL="apigee-test-cloudrun@$APIGEE_X_ORG.iam.gserviceaccount.com"

if [ -z "$(gcloud iam service-accounts list --filter "$SA_EMAIL" --format="value(email)"  --project "$APIGEE_X_ORG")" ]; then
    gcloud iam service-accounts create apigee-test-cloudrun \
        --description="Apigee Test Cloud Run" --project "$APIGEE_X_ORG"
fi

gcloud run services add-iam-policy-binding apigee-target-demo \
	 --member="serviceAccount:$SA_EMAIL" \
	 --role='roles/run.invoker' \
	 --region=us-west1 \
	 --platform=managed --project "$PROJECT_ID"

CLOUD_RUN_URL=$(gcloud run services list --filter apigee-target-demo --format="value(status.url)" --limit 1 )

TOKEN=$(gcloud auth print-access-token)

## Deploy using Cloud Build
gcloud services enable cloudbuild.googleapis.com
PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
CLOUD_BUILD_SA="$PROJECT_NUMBER@cloudbuild.gserviceaccount.com"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$CLOUD_BUILD_SA" \
  --role="roles/apigee.environmentAdmin"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$CLOUD_BUILD_SA" \
  --role="roles/apigee.apiAdmin"

gcloud builds submit --config='./ci-config/cloudbuild/cloudbuild.yaml' \
  --substitutions="_API_VERSION=google,_DEPLOYMENT_ORG=$PROJECT_ID,_APIGEE_TEST_ENV=$APIGEE_X_ENV,_CLOUD_RUN_URL=$CLOUD_RUN_URL,_SA_ACCOUNT=$SA_EMAIL,BRANCH_NAME=main"


response=$(curl "https://${APIGEE_X_HOSTNAME}/cloud-run/v0")

if [ "$response" != "Hello from Apigee" ];then
    echo "Got unexpected response: $response"
    exit 1
fi


# Clean up

if [ -z ${DELETE_AFTER_TEST+x} ] && [ "$DELETE_AFTER_TEST" != "false" ];then
    gcloud run services remove-iam-policy-binding apigee-target-demo \
	 --member="serviceAccount:$SA_EMAIL" \
	 --role='roles/run.invoker' \
	 --region=us-west1 \
	 --platform=managed --project "$PROJECT_ID"

    gcloud run services delete apigee-target-demo --region=us-west1 \
	 --platform=managed --project "$PROJECT_ID" -q || true
fi

