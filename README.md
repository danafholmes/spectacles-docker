# Incremental LookML Validation with Spectacles, Google Cloud Deploy, and GitHub


[Spectacles](https://www.spectacles.dev/) is a CI/CD tool that provides additional validation options beyond the standard LookML validation offered in Looker’s IDE. Some useful [features](https://docs.spectacles.dev/app/tutorials/validators#what-is-a-validator) Spectacles provide includes:

*   **SQL Validation** - run dummy queries against your database to check that the SQL specified for dimensions actually works in a query
    
*   **Non-IDE LookML Validation** \- Verify your LookML without using Looker’s IDE directly. Useful for validating machine-generated LookML or other changes pushed directly to git from a source external to Looker.
    
*   **Content Validation** \- Check Dashboards and Looks for broken queries
    
*   **Assert Validation** \- Run your pre-defined data tests outside of Looker
    

Spectacles offers a [CLI version](https://github.com/spectacles-ci/spectacles), which is open-source MIT License, as well as a hosted and fully managed [web application](https://www.spectacles.dev/pricing). Spectacles is written in python, and conveniently, can be installed from pip, making it a breeze to get up and running locally in the python environment of your choice to do run some ad-hoc tests.

While the hosted web application of Spectacles greatly simplifies integration into your Looker deploy process, it’s also possible to run the CLI client in a docker container and trigger the validators of your choice upon certain git events. There are some idiosyncrasies to triggering validation this way related to how Spectacles uses the Looker API that are mostly avoided in the Web application, but the trade-offs may be worth it to smaller teams without the budget for the hosted version.

Installing Locally
------------------

Before delving into deploying Spectacles in the cloud, it’s a good idea to install it locally and run a few validators to see how it all works.

There’s a thorough guide for this here, but the quick version is:

1.  Set up a python virtual environment using your preferred method to run the application in.
    
2.  From a console within your venv, run `pip install spectacles`
    
3.  [Create an API key](https://docs.spectacles.dev/cli/guides/how-to-create-an-api-key/) with the appropriate permissions.
    
4.  Create a `config.yaml` file with the following format:
    
    ```yaml
    # Replace with the URL of your Looker instance
    base_url: https://analyzely.looker.com
    # Replace with the actual values from your API key
    client_id: 4x2vgxNvCD3RYDM05gna
    client_secret: KDDwdDMm8MXyrJNqXBchbdmY
    ```
    
5.  Pick some validators you’re interested in and see if they run. Here, I’m telling Spectacles I want to validate the SQL in the **dana\_test** project, in the branch **deploy\_test**, and that I only want to run SQL queries for Explores that have had code that has changed (incremental validation).
    
    ```shell
    % spectacles sql \
    > --config-file config.yml \
    > --project dana_test \ 
    > --branch deploy_test \
    > --incremental
    ```
    
    If all goes well, you’ll see something like this:
    
    ```shell
    Connected to Looker version 22.10.18 using Looker API 3.1
    
    
    ==================== Testing 4 explores [concurrency = 10] =====================
    
    ✓ dana_test.affinity skipped
    ✓ dana_test.cohorts skipped
    ✓ dana_test.data_tool skipped
    ✓ dana_test.ecomm_predict passed
    ✓ dana_test.ecomm_training_info skipped
    ✓ dana_test.events skipped
    ✓ dana_test.inventory_snapshot skipped
    ✓ dana_test.journey_mapping passed
    ✓ dana_test.kmeans_model5 skipped
    ✓ dana_test.order_items passed
    ✓ dana_test.orders_with_share_of_wallet_application passed
    ✓ dana_test.pdt_test skipped
    ✓ dana_test.sessions skipped
    
    Completed SQL validation in 55 seconds.
    ```
    
6.  If you run into any application or authentication errors, resolve them before moving to deploying in the Cloud - they’re a lot easier to resolve working locally. The most likely failure point would be bad API credentials or incorrect permissions for the API credential you created.
    

Building the Docker Image
-------------------------

In order to deploy Spectacles in the cloud and run it as part of our Deploy process, first we need to build a Docker image that has Spectacles and all of the required dependencies installed. We could also build this Docker image each time we trigger a run as part of our build process, but since we’re not actually building the image with new files from our repo, there’s really no need - we can just build the image once and store it in Artifact Registry.

I have the Dockerfile and requirements files for this example stored in a public git repo here: [https://github.com/dana-4mile/spectacles-docker](https://github.com/dana-4mile/spectacles-docker)

1.  Follow Google’s documentation to set up and permission an Artifact Registry: [https://cloud.google.com/artifact-registry/docs/docker/store-docker-container-images](https://cloud.google.com/artifact-registry/docs/docker/store-docker-container-images)
    
2.  In Google Cloud Shell, clone the repo:
    
    ```shell
    $ git clone https://github.com/dana-4mile/spectacles-docker
    ```
    
    The Dockerfile contains the build instructions for the docker image:
    
    ```docker
    FROM python:3.10
    
    # Allow statements and log messages to immediately appear in the Cloud Run logs
    ENV PYTHONUNBUFFERED True
    
    COPY requirements.txt ./
    COPY requirements-composer.txt ./
    COPY requirements-test.txt ./
    
    RUN pip install --no-cache-dir -r requirements.txt
    RUN pip install --no-cache-dir -r requirements-test.txt
    RUN pip install --no-cache-dir -r requirements-composer.txt
    
    CMD ["sh", "-c", "spectacles sql --base-url https://4mile.looker.com --client-id $SPECTACLES_ID --client-secret $SPECTACLES_SECRET --verbose --project dana_test --branch $_HEAD_BRANCH --incremental"]
    ```
    
    *   **FROM** tells docker to build the image starting from the python:3.10 image, which is a minimal Linux image with python 3.10 installed.
        
    *   **ENV PYTHONUNBUFFERED** allows logs to show up in the Cloud Build logs from our python application
        
    *   **COPY** copies requirements files from the repo and builds them into our image.
        
    *   **RUN pip install** installs the requirements specified in our files.
        
    *   **CMD** specifies a default command to run when the container starts up. In this case, we are telling docker that when the container runs, it should run a sh shell, and in that shell, run the spectacles test from earlier.  
          
        This command should look familiar from earlier, however you’ll notice we’re passing API credentials with flags rather than from a yaml file. The --verbose flag is also specified to get more information back in case the build fails - for example API response codes etc.  
          
        We’re also using environment variables for the client ID, client secret, and head branch - we’ll pass these to the docker container at run time from Google Secret Manager and Google Cloud Build.
        
3.  Build the docker image, where $REGION is the region you set the registry up in, $PROJECT\_ID is your GCP project ID, and $ARTIFACT\_REGISTRY is the name of the artifact registry specified earlier:
    
    ```shell
    docker build -t ${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REGISTRY}/spectacles-sql-validator:v1 .
    ```
    
4.  Push the Docker image to your artifact registry:
    
    ```shell
    docker push ${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REGISTRY}/spectacles-sql-validator:v1
    ```
    
    If you view the Artifacts within the artifact registry you set up earlier, you should now see this new image:
    
    ![assets](../assets/1388478473.png)
    

Add Your Looker API Secret to Google Secret Manager
---------------------------------------------------

![assets](../assets/1389232142.png)

Google Secret manager allows you to securely store API keys and other passwords, then access them across GCP. In Cloud Build, we can access them as environment variables and pass them to the Docker Container to authenticate with the Looker API for the spectacles validation process. Storing a secret is very straight forward, so I’ll let Google explain.

[https://cloud.google.com/secret-manager/docs/create-secret](https://cloud.google.com/secret-manager/docs/create-secret)

I called my secrets “spectacles\_id” and “spectacles\_secret” for the Looker API ID and Secret respectively. You can call them whatever you’d like, but you’ll have to edit the cloud build file in the next step to reflect those changes if you do.  
  
It’s also worth noting that you don’t technically _have_ to store your API ID as a secret, because it’s not particularly sensitive - but the cost of Secret Manager is basically nil and it’s a nice easy way to manage the credentials in one place should they change.

Create a Cloud Build Trigger
----------------------------

[https://cloud.google.com/build/docs/automating-builds/create-manage-triggers](https://cloud.google.com/build/docs/automating-builds/create-manage-triggers)

Now for the interesting part. Follow the instructions in the above guide to enable Cloud Build API and go through initial setup. You’ll need to go through the setup steps to [install and authorize the GitHub app](https://cloud.google.com/build/docs/automating-builds/build-repos-from-github) for your repo as well. When all that is done, create a new trigger:

![assets](../assets/1389264908.png)

*   **Source** should be the GitHub repository where your Looker project is stored. Since I’m running this on my **dana\_test** project in Looker, I’m pointing it at the repo for that, which somewhat confusingly I named looker-test.
    
*   For **Event**, I want this trigger to run when a PR is created. That way my SQL test runs on each PR that is opened, and the PR reviewer can take the results into account when they are deciding if they should approve the PR.
    
*   For **Base branch**, I have the regex to match only master branch of my project. This means that the trigger will only run when someone creates a PR to merge a changes into the master branch.
    

![assets](../assets/1389264914.png)

*   **Comment Control** allows you to require a comment on the PR to run the test. This isn’t a huge concern on this repo since it’s private, but if the repo were public this option would prevent random GitHub users from flooding you with PRs and wasting resources running useless tests.
    
*   For **Configuration**, select Cloud Build configuration file. Here you have two options - from the spectacles-docker repo we cloned earlier, you could either copy `test-spectacles.cloudbuild.yaml` into your Looker project repository’s root directory, or paste the YAML Inline in the Cloud Build trigger. Whatever you decide, this is what the Cloud Build file will tell the trigger to do:
    
    ```yaml
    steps:
      - name: >-
          us-west1-docker.pkg.dev/${PROJECT_ID}/spectacles-test/spectacles-sql-validator:v1
        env:
          - _HEAD_BRANCH=$_HEAD_BRANCH
          - _BASE_BRANCH=$_BASE_BRANCH
          - PROJECT_ID=$PROJECT_ID
        id: test-sql
        secretEnv:
          - SPECTACLES_ID
          - SPECTACLES_SECRET
    availableSecrets:
      secretManager:
        - versionName: 'projects/${PROJECT_ID}/secrets/spectacles_id/versions/1'
          env: SPECTACLES_ID
        - versionName: 'projects/${PROJECT_ID}/secrets/spectacles_secret/versions/1'
          env: SPECTACLES_SECRET
    ```
    
*   **steps:** defines the steps the build process should take. In this case, we just have one step - running the Docker image we build and published earlier.
    
    *   **name:** We’re using the name of the image we created and registered in artifact registry earlier.
        
    *   **env:** We’re passing some [built-in variables](https://cloud.google.com/build/docs/configuring-builds/substitute-variable-values) to the cloud builder - our head branch, base branch, and project id.
        
    *   **id:** What the build step is called.
        
    *   **secretEnv:** Secrets, as defined in the availableSecrets key, that we want available to this build step - these are defined below in availableSecrets. These will be available as environment variables in the container. The substitution syntax is a prefix of a double $$, rather than a single $.
        
*   **availableSecrets:** Defines the secrets we want to import from the Secret manager and make available to this cloud build trigger - more on that in the “Using secrets” link above.
    

**Save** the trigger, and verify that it shows up in the List of triggers:

![assets](../assets/1388445725.png)

Putting it All Together
-----------------------

### Opening a PR

Create a **Pull Request** from a Dev Branch in Looker within the project you have the trigger set up for. It shouldn’t matter if you create this PR from the Looker IDE or directly from GitHub.

You’ll see that the “Checks” tab now has one item - the SQL validation step we just defined. You’ll also see that above the merge button, we get a progress report on our SQL test’s status:

![assets](../assets/1388380191.png)

On the Checks tab, there’s a few more details, and link to the build Logs in Cloud Build. In this case the validation succeeded, but if the validation failed, the logs in Cloud Build are where you’d actually see why.

![assets](../assets/1388904457.png)

Had the test failed, the checks tab would show a failed test:

![assets](../assets/1389002757.png)

It’s worth noting that non-LookML related errors could cause the check to fail, so a reviewer would always want to check the logs to see the precise reason for the failure. For example, a communication failure with the API, or an issue with Looker being able to communicate with the Database, or a concurrency issue with your database could all cause this check to fail, but wouldn’t necessarily indicate that there’s actually anything wrong with the LookML.

### Viewing the Logs

The build log will contain the verbose output of the Spectacles CLI app. Here, you can see if your test passed, and if not, what dimensions it failed on.

![assets](../assets/1388838927.png)

### Incremental Validation

You can verify that the incremental validation is working by comparing the Files changed tab in GitHub with the tests run from the Spectacles Logs. For this SQL test, only Explores that query views that have changed should be tested.

In this case, I made a change to the **order\_items** view:

![assets](../assets/1388576814.png)

And in the logs, I can see that Spectacles only ran test queries against the Explores that contain Order Items as a base or a join:

![assets](../assets/1389133837.png)

The “skipped” tests are tests that were generated, but determined to be unnecessary because the explores don’t use the order\_items view.

The “gotchas”
-------------

### API Concurrency

Spectacles uses a user account to access the Looker API. This opens up a possible concurrency issue - theoretically, if two users opened a PR at the same time, the second validator run could invoke the API to switch to an undesired branch in the middle of validation, and run some of the tests on the wrong branch.

[https://docs.spectacles.dev/cli/guides/how-to-deploy-spectacles](https://docs.spectacles.dev/cli/guides/how-to-deploy-spectacles)

This is most likely to be an issue on large Enterprise Looker Instances that might have dozens of developers working on a single project. On smaller projects with only a few developers, it seems quite unlikely that multiple users would submit a PR at the exact same time, and the team could easily communicate to prevent doing so.

Regardless - the hosted version of Spectacles solves this concurrency issue, and for larger teams is probably worth the cost of admission for that alone.

Next Steps
----------

This is a very basic implementation - we built a very simple Docker image to run one test in one specific scenario. Implementing this in production, you might want to:

*   Modify the docker image so Spectacles is run from a shell script built into the image that accepts some environment variables so you can invoke different tests from the same Docker image
    
*   Specify versions for the Looker SDK and Spectacles in the requirements.txt file and rebuild the image
    
*   Weigh the pros and cons of running the 3.1 or 4.0 API version (selectable by a flag when running Spectacles)
    
*   Set up Cloud Build Triggers for the other types of Spectacles Validators
    
*   Dial in permissions for Git and Cloud Deploy to ensure that PR approvers can see the Build Logs but can’t modify the trigger.
