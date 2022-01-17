.PHONY: clean dev env help lock test deploy-users validate-cloudformation

cloudformation-directory := cloudformation
cloudformation-files := $(shell find $(cloudformation-directory) -name '*.yml')
deploy-role ?= admin

ifneq (,$(wildcard ./.env))
include .env
endif

# This is a self documenting make file.  ## Comments after the command are the help
# options.
help:  ## List available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

clean:  ## Clean build
	rm -f .test
	rm -f .env
	rm -f .dev

.lock: .env Pipfile
	pipenv --clear
	PYPI_TOKEN=$(PYPI_TOKEN) pipenv lock -v --clear
	@touch .lock

.dev: .lock Makefile
	PYPI_TOKEN=$(PYPI_TOKEN) pipenv sync --dev
	@touch .dev

.test: .env $(cloudformation-files)
	$(MAKE) validate-cloudformation cf-file=kolvir-web.yaml
	$(MAKE) validate-cloudformation cf-file=certificate.yaml
	touch .test

dev: .dev ## Install dependencies (useful for dev editor linting, not used for run/test/etc)

lock: .lock  ## Relock python depends

test: .test  ## Run tests

cf-file ?=
validate-cloudformation: .dev
	pipenv run python -m kolvir.aws.assume_role --role $(deploy-role) --mfa \
		aws cloudformation validate-template \
			--no-cli-pager \
			--template-body file://./cloudformation/${cf-file}

service ?= www
domain-name :=
hosted-zone-id :=
certificate-arn :=
.PHONY: deploy-frontend
deploy-frontend: .dev .test
	$(eval hosted-zone-id := $(patsubst "%",%,$(shell \
		AWS_PAGER="" pipenv run python -m kolvir.aws.assume_role \
			--role $(deploy-role) --mfa \
		aws cloudformation list-exports \
			--query "Exports[?Name=='zone-public-HostedZoneId'].Value | [0]")))
	$(eval domain-name := $(patsubst "%",%,$(shell \
		AWS_PAGER="" pipenv run python -m kolvir.aws.assume_role \
			--role $(deploy-role) --mfa \
		aws cloudformation list-exports \
			--query "Exports[?Name=='domain-names-DomainName'].Value | [0]")))
	pipenv run python -m kolvir.aws.assume_role --role $(deploy-role) --mfa \
		aws --region us-east-1 cloudformation deploy \
			--stack-name kolvir-web-certificate \
			--no-fail-on-empty-changeset \
			--capabilities CAPABILITY_NAMED_IAM \
			--template-file cloudformation/certificate.yaml \
			--parameter-overrides \
				SubDomainName=$(service) \
				DomainName=$(domain-name) \
				HostedZoneId=$(hosted-zone-id)
	sleep 3
	$(eval certificate-arn := $(patsubst "%",%,$(shell \
		AWS_PAGER="" pipenv run python -m kolvir.aws.assume_role \
			--role $(deploy-role) --mfa \
		aws --region us-east-1 cloudformation list-exports \
			--query "Exports[?Name=='kolvir-web-certificate-CertificateARN'].Value | [0]")))
	pipenv run python -m kolvir.aws.assume_role --role $(deploy-role) --mfa \
		aws cloudformation deploy \
			--stack-name kolvir-web \
			--no-fail-on-empty-changeset \
			--capabilities CAPABILITY_NAMED_IAM \
			--template-file cloudformation/kolvir-web.yaml \
			--parameter-overrides \
				SubDomainName=$(service) \
				AcmCertificateArn=$(certificate-arn)

s3-bucket-name :=
deploy-artifacts:
	$(eval s3-bucket-name := $(patsubst "%",%,$(shell \
		AWS_PAGER="" pipenv run python -m kolvir.aws.assume_role \
			--role $(deploy-role) --mfa \
		aws cloudformation list-exports \
			--query "Exports[?Name=='kolvir-web-S3BucketWebName'].Value | [0]")))
	pipenv run python -m kolvir.aws.assume_role --role $(deploy-role) --mfa \
		aws s3 sync --acl "public-read" app/build/ s3://$(s3-bucket-name)
