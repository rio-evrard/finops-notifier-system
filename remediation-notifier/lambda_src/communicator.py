import os
import json
import logging
import boto3
import urllib3
import re

# --- Configure Structured Logging ---
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def log_event(level, event_name, data=None):
    payload = {"component": "communicator_lambda", "event": event_name, "data": data or {}}
    if level == "ERROR":
        logger.error(json.dumps(payload, default=str))
    elif level == "WARN":
        logger.warning(json.dumps(payload, default=str))
    else:
        logger.info(json.dumps(payload, default=str))

# Initialize clients
s3_client = boto3.client('s3')
org_client = boto3.client('organizations')
http = urllib3.PoolManager()

# Cache the webhook map across warm invocations
WEBHOOK_MAP = None

def get_account_name(account_id):
    """Attempts to resolve the AWS Account Name from the Account ID using Organizations API."""
    try:
        response = org_client.describe_account(AccountId=account_id)
        return response['Account']['Name']
    except Exception as e:
        log_event("WARN", "AccountNameResolutionFailed", {"account_id": account_id, "error": str(e)})
        return None

def normalize_account_name(account_name):
    """Strips standard environment suffixes so it matches the GitOps webhook map."""
    if not account_name:
        return None
    # Add any other suffixes your organization uses inside the parentheses separated by |
    return re.sub(r'-(dev|prod|test|acc|qa|sandbox|uat|prev)$', '', account_name, flags=re.IGNORECASE)

def get_webhook_map():
    """Loads the JSON configuration file from S3."""
    global WEBHOOK_MAP
    if WEBHOOK_MAP is not None:
        return WEBHOOK_MAP

    bucket = os.environ.get('WEBHOOK_MAP_BUCKET')
    key = os.environ.get('WEBHOOK_MAP_KEY')
    
    log_event("INFO", "LoadingWebhookMap", {"bucket": bucket, "key": key})
    try:
        response = s3_client.get_object(Bucket=bucket, Key=key)
        content = response['Body'].read().decode('utf-8')
        account_data = json.loads(content)
        
        # Build mapping
        WEBHOOK_MAP = {
            item.get('account_name'): item.get('webhook')
            for item in account_data if item.get('webhook')
        }
        log_event("INFO", "WebhookMapLoaded", {"mapping_count": len(WEBHOOK_MAP)})
        return WEBHOOK_MAP
    except Exception as e:
        log_event("ERROR", "WebhookMapLoadFailed", {"error": str(e)})
        return {}

def format_teams_card(bucket_name, account_id, account_name, action_taken):
    card = {
        "type": "message",
        "attachments": [{
            "contentType": "application/vnd.microsoft.card.adaptive",
            "content": {
                "type": "AdaptiveCard",
                "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                "version": "1.5",
                "msteams": {"width": "Full"},
                "body": [
                    {"type": "TextBlock", "text": "🚨 Security Auto-Remediation Triggered", "weight": "Bolder", "size": "Large", "color": "Attention"},
                    {"type": "TextBlock", "text": "An S3 bucket was misconfigured to log to itself, creating an infinite loop. The system has automatically disabled logging on this bucket to prevent cost spikes.", "wrap": True},
                    {"type": "FactSet", "facts": [
                        {"title": "**Account:**", "value": f"{account_name or 'Unknown'} (`{account_id}`)"},
                        {"title": "**Bucket Name:**", "value": f"`{bucket_name}`"},
                        {"title": "**Action Taken:**", "value": action_taken}
                    ]},
                    {"type": "TextBlock", "text": "**Next Steps:** If server access logging is required for this bucket, please configure it to point to a designated, separate logging bucket.", "wrap": True}
                ]
            }
        }]
    }
    return json.dumps(card).encode('utf-8')

def lambda_handler(event, context):
    """Processes messages delivered by SQS."""
    log_event("INFO", "SQSBatchReceived", {"records_count": len(event.get('Records', []))})
    
    webhook_map = get_webhook_map()
    
    for record in event.get('Records', []):
        try:
            message_body = json.loads(record['body'])
            account_id = message_body.get('account_id')
            bucket_name = message_body.get('bucket_name')
            action_taken = message_body.get('action_taken', "Server Access Logging Disabled")
            original_account_name = get_account_name(account_id)
            lookup_name = normalize_account_name(original_account_name)
            
            webhook_url = webhook_map.get(lookup_name) or webhook_map.get("default")
            
            if not webhook_url:
                log_event("WARN", "NotificationSkipped", {
                    "reason": "No webhook URL found", 
                    "original_account_name": original_account_name,
                    "lookup_name_attempted": lookup_name
                })
                continue 

            # Pass the ORIGINAL name to the card formatting
            card_payload = format_teams_card(bucket_name, account_id, original_account_name, action_taken)
            
            response = http.request('POST', webhook_url, body=card_payload, headers={'Content-Type': 'application/json'})
            
            if response.status >= 400:
                raise Exception(f"Teams API returned status {response.status}")
                
            log_event("INFO", "NotificationSent", {"bucket": bucket_name, "status_code": response.status})

        except Exception as e:
            log_event("ERROR", "RecordProcessingFailed", {"error": str(e), "record_body": record.get('body')})
            raise e 
            
    return {'statusCode': 200, 'body': 'Batch processed successfully.'}