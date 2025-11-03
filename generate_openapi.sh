#!/bin/bash

# Script to generate and fix the OpenAPI specification

echo "🔧 Generating OpenAPI spec..."
mix openapi.spec.json --spec BatcherWeb.AshJsonApiRouter 2>&1 | grep -v "alarm_handler\|dets:\|os_mon\|live_debugger"

echo "🔧 Fixing union types..."
mix openapi.fix_union 2>&1 | grep -v "alarm_handler\|dets:\|os_mon\|live_debugger"

echo ""
echo "✅ OpenAPI spec generated successfully!"
echo ""
echo "📖 View documentation:"
echo "   • Swagger UI: http://localhost:4000/api/json/swaggerui"
echo "   • OpenAPI JSON: http://localhost:4000/api/json/open_api"
echo "   • Or view: openapi.json"
