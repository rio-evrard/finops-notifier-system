import os
import json
import logging
import boto3

# --- Configure Structured Logging ---
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def log_event(level, event_name, data=None):
    payload = {"component": "remediator_lambda", "event": event_name, "data": data or {}}
    if level == "ERROR":
        logger.error(json.dumps(payload, default=str))
    elif level == "WARN":
        logger.warning(json.dumps(payload, default=str))
    else:
        logger.info(json.dumps(payload, default=str))

# Initialize clients
sqs_client = boto3.client('sqs')
sts_client = boto3.client('sts')

SQS_QUEUE_URL = os.environ.get('SQS_QUEUE_URL')

def assume_workload_role(account_id):
    role_arn = f'arn:aws:iam::{account_id}:role/WorkloadEventRemediationRole' 
    log_event("INFO", "AssumingRole", {"role_arn": role_arn})
    response = sts_client.assume_role(
        RoleArn=role_arn,
        RoleSessionName='S3LoggingAutoRemediation'
    )
    return response['Credentials']

def disable_bucket_logging(account_id, bucket_name):
    creds = assume_workload_role(account_id)
    workload_s3 = boto3.client(
        's3',
        aws_access_key_id=creds['AccessKeyId'],
        aws_secret_access_key=creds['SecretAccessKey'],
        aws_session_token=creds['SessionToken'],
    )
    
    log_event("INFO", "ExecutingRemediation", {"bucket": bucket_name, "account_id": account_id})
    # Passing an empty BucketLoggingStatus dict completely disables logging
    workload_s3.put_bucket_logging(
        Bucket=bucket_name,
        BucketLoggingStatus={}
    )

def push_to_sqs(account_id, bucket_name):
    message_body = {
        "account_id": account_id,
        "bucket_name": bucket_name,
        "action_taken": "Server Access Logging Disabled"
    }
    log_event("INFO", "PushingToSQS", {"queue": SQS_QUEUE_URL, "message": message_body})
    sqs_client.send_message(
        QueueUrl=SQS_QUEUE_URL,
        MessageBody=json.dumps(message_body)
    )

def lambda_handler(event, context):
    try:
        log_event("DEBUG", "RawEventReceived", {"event": event})
        
        detail = event.get('detail', {})
        account_id = detail.get('recipientAccountId') 
        req_parameters = detail.get('requestParameters', {})
        
        bucket_name = req_parameters.get('bucketName')
        if not bucket_name:
            log_event("WARN", "MissingBucketName", {"detail": detail})
            return

        logging_status = req_parameters.get('BucketLoggingStatus', {})
        logging_enabled = logging_status.get('LoggingEnabled')
        
        # If LoggingEnabled is missing, someone turned off logging. We can safely ignore.
        if not logging_enabled:
            log_event("INFO", "LoggingDisabledByAccount", {"bucket": bucket_name})
            return

        target_bucket = logging_enabled.get('TargetBucket')

        # EVALUATION LOGIC: Does the bucket log to itself?
        if bucket_name == target_bucket:
            log_event("WARN", "MisconfigurationDetected", {
                "source_bucket": bucket_name, 
                "target_bucket": target_bucket,
                "account_id": account_id
            })
            
            # 1. Execute Remediation
            disable_bucket_logging(account_id, bucket_name)
            log_event("INFO", "RemediationSuccessful", {"bucket": bucket_name})
            
            # 2. Push to SQS for Communication
            push_to_sqs(account_id, bucket_name)
            
        else:
            log_event("INFO", "ConfigurationValid", {
                "source_bucket": bucket_name, 
                "target_bucket": target_bucket
            })

    except Exception as e:
        log_event("ERROR", "HandlerExecutionFailed", {"error": str(e)})
        raise e # Let EventBridge handle retries for compute failures
        
    return {'statusCode': 200, 'body': 'Evaluation complete.'}