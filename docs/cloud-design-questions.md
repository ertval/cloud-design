#### General

##### Check the repository content.

Files that must be inside the repository:

- Detailed documentation in the `README.md` file.
- Source code for the microservices and scripts required for deployment.
- Configuration files for AWS Infrastructure as Code (IaC), containerization, and orchestration tools.

###### Are all the required files present?

##### Play the role of a stakeholder.

Organize a simulated scenario where learners take on the role of AWS Cloud
engineers and present their solution to a team or stakeholder. Evaluate their
understanding of the concepts and technologies used in the project, their
communication skills, and their ability to think critically about their
solution.

Suggested role-play questions include:

- What is the cloud and its associated benefits?
- Why is deploying the solution in the cloud preferred over on-premises?
- How would you differentiate between public, private, and hybrid cloud?
- What drove your decision to select AWS for this project, and what factors did you consider?
- Can you describe your microservices application's AWS-based architecture and the interaction between its components?
- How did you manage and optimize the cost of your AWS solution?
- What measures did you implement to ensure application security on AWS, and what AWS security best practices did you adhere to?
- What AWS monitoring and logging tools did you utilize, and how did they assist in identifying and troubleshooting application issues?
- Can you describe the AWS auto-scaling policies you implemented and how they help your application accommodate varying workloads?
- How did you optimize Docker images for each microservice, and how did this
  impact build times, image sizes?
- If you had to redo this project, what modifications would you make to your approach or the technologies you used?
- How can your AWS solution be expanded or altered to cater to future requirements like adding new microservices or migrating to a different cloud provider?
- What challenges did you face during the project and how did you address them?
- How did you ensure your documentation's clarity and completeness, and what measures did you take to make it easily understandable and maintainable?

###### Were the learners able to answer all the questions correctly?

###### Did the learners demonstrate a thorough understanding of the concepts and technologies used in the project?

###### Were the learners able to communicate effectively and justify their decisions?

###### Could the learners critically evaluate their solution and consider alternative strategies?

##### Review the Architecture Design.

Review the learner's architecture design, ensuring that it meets the project requirements:

1. `Scalability`: Does the architecture utilize AWS services to manage varying workloads and scale as required?
2. `Availability`: Is the architecture designed to be fault-tolerant and maintain high availability, even during component failures?
3. `Security`: Does the architecture integrate AWS security best practices,
   including data encryption, use of AWS VPC, secure API endpoints, and managed
   authentication using AWS Cognito or a similar service?
4. `Cost-effectiveness`: Is the architecture designed to be cost-effective on AWS without compromising performance, security, or scalability?
5. `Simplicity`: Is the AWS architecture straightforward and free of unnecessary complexity while still fulfilling project requirements?

###### Did the architecture design and choice of services align with all the project requirements above?

###### Were the learners able to design a cost-effective architecture that meets the project requirements?

##### Check the learner documentation in the `README.md` file.

###### Does the `README.md` file contain all the necessary information about the solution (prerequisites, setup, configuration, usage, ...)?

###### Is the documentation provided by the learner clear and complete, including well-structured diagrams and thorough descriptions?

##### Verify the deployment. Ask the learner to show you, the auditor, the use of `aws cli`, and either `kubectl` (for EKS) or relevant ECS commands, as well as `docker ps` if applicable.

###### Was the learner able to show you the proper usage of the commands to verify the deployment of the microservices in the cloud environment?

###### Are all the microservices running as expected in the cloud environment, with no errors or connectivity issues?

###### Is the load balancing configured correctly, effectively distributing traffic across the services?

###### Are the microservices communicating with each other securely, using proper authentication and encryption methods?

##### Verify API functionality through the API Gateway.

###### Can the learner successfully create a movie by sending a POST request through the API Gateway, and does the request return a successful response code?

###### Can the learner retrieve the created movies by sending a GET request through the API Gateway, and does the response contain the expected data?

##### Verify billing service and messaging queue resilience.

###### When the billing service is stopped, can the learner send a billing request through the API Gateway without errors?

###### After restarting the billing service, does the learner demonstrate that the queued billing request was processed successfully?

##### Evaluate the infrastructure setup. Ask the learner **to show you**, the auditor, the use of the commands `terraform plan` and/or `terraform apply` to answer the following questions.

###### Is `Terraform` used effectively to provision and manage resources in the cloud environment?

###### Does the infrastructure setup follow the architecture design and the project requirements?

##### Assess containerization and orchestration. Ask the learner **to show you**, the auditor, the use of the commands `aws cli`, `docker ps`, and/or `kubectl` or any other necessary with the right options to answer the following questions.

###### Are the Dockerfiles optimized for efficient container builds?

###### Is the orchestration setup (e.g., Kubernetes manifests or AWS ECS task definitions) configured correctly?

##### Evaluate monitoring and logging.

###### Are monitoring and logging dashboards providing useful insights into the application performance and health?

##### Assess optimization efforts.

###### Are the auto-scaling policies configured correctly to handle varying workloads?

###### Does the application and resource allocation remain efficient under different load scenarios?

##### Check security best practices.

###### Has the learner implemented security best practices, such as using HTTPS, securing API endpoints, restricting database access to the VPC, and regularly scanning for vulnerabilities?

###### When accessing the API Gateway without valid authentication credentials, is the request correctly rejected?

###### Can the learner demonstrate the managed authentication configuration (e.g., Cognito) used to protect the API Gateway?

#### Bonus

###### +Did the learner add any optional bonus?

###### +Is this project an outstanding project?
