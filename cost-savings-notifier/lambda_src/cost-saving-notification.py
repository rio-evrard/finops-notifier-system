import os
import json
import logging
import boto3
import urllib3
from collections import defaultdict

# --- Configure Structured Logging ---
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def log_event(level, event_name, data=None):
    """Emits structured JSON logs for CloudWatch Insights"""
    payload = {
        "component": "cost_savings_notifier",
        "event": event_name,
        "data": data or {}
    }
    if level == "ERROR":
        logger.error(json.dumps(payload, default=str))
    elif level == "WARN":
        logger.warning(json.dumps(payload, default=str))
    else:
        logger.info(json.dumps(payload, default=str))

# Initialize AWS and HTTP clients
s3_client = boto3.client('s3')
athena_client = boto3.client('athena')
http = urllib3.PoolManager()

# --- Environment Variables ---
WEBHOOK_MAP_BUCKET = os.environ.get('WEBHOOK_MAP_BUCKET')
WEBHOOK_MAP_KEY = os.environ.get('WEBHOOK_MAP_KEY')

MIGRATION_DOC_URL = os.environ.get('MIGRATION_DOC_URL', 'https://your-internal-wiki.example.com/cost-optimization')

def get_webhook_map():
    log_event("INFO", "LoadingWebhookMap", {"bucket": WEBHOOK_MAP_BUCKET, "key": WEBHOOK_MAP_KEY})
    try:
        response = s3_client.get_object(Bucket=WEBHOOK_MAP_BUCKET, Key=WEBHOOK_MAP_KEY)
        content = response['Body'].read().decode('utf-8')
        account_data = json.loads(content)
        
        webhook_map = {
            item['key_contact']: item['webhook']
            for item in account_data if 'webhook' in item and 'key_contact' in item
        }
        log_event("INFO", "WebhookMapLoaded", {"mapping_count": len(webhook_map)})
        return webhook_map
    except Exception as e:
        log_event("ERROR", "WebhookMapLoadFailed", {"error": str(e)})
        return {}

def format_teams_card(owner_email, findings, total_savings):
    owner_name = owner_email.split('@')[0].replace('.', ' ').title()
    instance_facts = []
    
    sorted_findings = sorted(findings, key=lambda x: x['savings'], reverse=True)
    
    display_limit = 10
    top_findings = sorted_findings[:display_limit]
    hidden_count = len(sorted_findings) - display_limit
    
    for finding in top_findings:
        instance_facts.append({"title": f"**Resource ID:**", "value": f"`{finding['resource_id']}` ({finding['resource_type']})"})
        instance_facts.append({"title": f"**Recommended Type:**", "value": f"`{finding['recommended_type']}`"})
        instance_facts.append({"title": f"**Est. Savings:**", "value": f"${finding['savings']:.2f}/month"})

    if hidden_count > 0:
        instance_facts.append({"title": f"**... And {hidden_count} more**", "value": "View AWS Cost Optimization Hub for full list."})

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
                    {"type": "TextBlock", "text": "🚀 Graviton Migration Opportunity", "weight": "Bolder", "size": "Large"},
                    {"type": "TextBlock", "text": f"Dear Application team, we've identified Graviton migration candidates in your workload that can improve performance and reduce costs.", "wrap": True},
                    {"type": "TextBlock", "text": f"**Total Estimated Monthly Savings: ${total_savings:.2f}**", "wrap": True, "weight": "Bolder", "size": "Medium", "color": "Good"},
                    {"type": "FactSet", "facts": instance_facts},
                    {"type": "TextBlock", "text": "**Action Required:** Please review the recommendations and plan for migration.", "wrap": True, "weight": "Bolder"},
                    {"type": "ActionSet", "actions": [{"type": "Action.OpenUrl", "title": "View Full Migration Guide", "url": MIGRATION_DOC_URL}]}
                ]
            }
        }]
    }
    return json.dumps(card).encode('utf-8')

def parse_athena_map_string(map_str):
    if not map_str or not map_str.strip() or map_str == '{}':
        return {}
    try:
        pairs = map_str.strip('{}').split(', ')
        return dict(pair.split('=', 1) for pair in pairs)
    except ValueError:
        log_event("WARN", "MapStringParseFailed", {"map_str": map_str})
        return {}

def process_athena_results(execution_id):
    # Notice: No while/sleep loop! We assume the Step Function only calls us when SUCCEEDED.
    log_event("INFO", "FetchingAthenaResults", {"execution_id": execution_id})
    
    results_paginator = athena_client.get_paginator('get_query_results')
    results_iter = results_paginator.paginate(QueryExecutionId=execution_id, PaginationConfig={'PageSize': 1000})
    
    findings_by_owner = defaultdict(lambda: {'findings': [], 'total_savings': 0.0})
    
    rows = [row for page in results_iter for row in page['ResultSet']['Rows']]
    if len(rows) <= 1:
        log_event("INFO", "AthenaReturnedNoRows")
        return findings_by_owner
        
    headers = [col['VarCharValue'] for col in rows[0]['Data']]
    
    for i, row in enumerate(rows[1:]):
        data = dict(zip(headers, [d.get('VarCharValue') for d in row['Data']]))
        try:
            tags = parse_athena_map_string(data.get('tags', '{}'))
            owner_email = next((v for k, v in tags.items() if k.lower() == 'owner'), None)

            if not owner_email:
                continue

            savings = float(data.get('savings', 0))
            
            findings_by_owner[owner_email]['findings'].append({
                'resource_id': data.get('resource_id'),
                'resource_type': data.get('resource_type'),
                'recommended_type': data.get('recommended_instance_type'),
                'savings': savings
            })
            findings_by_owner[owner_email]['total_savings'] += savings
        except (TypeError, ValueError) as e:
            log_event("WARN", "RowProcessingFailed", {"row_index": i+1, "error": str(e), "row_data": data})
            continue
            
    log_event("INFO", "ResultsProcessed", {"unique_owners_found": len(findings_by_owner)})
    return findings_by_owner

def lambda_handler(event, context):
    log_event("INFO", "GravitonNotifierExecutionStarted")
    
    # 1. Retrieve the execution ID passed by the Step Function
    execution_id = event.get('execution_id')
    if not execution_id:
        log_event("ERROR", "MissingExecutionId", {"event": event})
        return {'statusCode': 400, 'body': 'Execution ID missing from payload.'}

    webhook_map = get_webhook_map()
    if not webhook_map:
        log_event("ERROR", "ExecutionAborted", {"reason": "Webhook map empty or failed to load"})
        return {'statusCode': 500, 'body': 'Failed to load webhook map.'}
        
    try:
        # 2. Process the results directly using the provided execution ID
        findings_by_owner = process_athena_results(execution_id)
        
        if not findings_by_owner:
            log_event("INFO", "ExecutionCompleted", {"status": "No actionable findings."})
            return {'statusCode': 200, 'body': 'No actionable findings for any owners.'}
            
        for owner_email, data in findings_by_owner.items():
            if owner_email not in webhook_map:
                log_event("WARN", "OwnerNotInWebhookMap", {"owner_email": owner_email})
                continue
            
            if not data['findings']:
                continue
            
            webhook_url = webhook_map[owner_email]
            card_payload = format_teams_card(owner_email, data['findings'], data['total_savings'])
            
            try:
                r = http.request('POST', webhook_url, body=card_payload, headers={'Content-Type': 'application/json'})
                log_event("INFO", "NotificationSent", {
                    "owner_email": owner_email, 
                    "resource_count": len(data['findings']),
                    "total_savings": data['total_savings'],
                    "status_code": r.status
                })
            except Exception as e:
                log_event("ERROR", "NotificationFailed", {"owner_email": owner_email, "error": str(e)})
                
    except Exception as e:
        log_event("ERROR", "UnhandledException", {"error": str(e)})
        return {'statusCode': 500, 'body': str(e)}

    log_event("INFO", "GravitonNotifierExecutionFinished")
    return {'statusCode': 200, 'body': 'Processing complete.'}