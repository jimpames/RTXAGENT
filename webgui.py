this is to be added to they webgui.py
# Add these imports at the top if not already present
from fastapi import Query
from pydantic import BaseModel, HttpUrl

# Add this model class with your other models
class RTXNodeRegistration(BaseModel):
    node_id: str
    tunnel_url: str
    models: List[dict] = []
    system_info: dict = {}

# Add this route to your existing FastAPI app
@app.get("/addme")
async def add_rtx_node(
    node_id: str = Query(..., description="Unique ID of the RTX node"),
    url: str = Query(..., description="Ngrok tunnel URL"),
    type: str = Query("windows", description="Node type")
):
    logger.info(f"RTX node registration request: {node_id} at {url}")
    
    try:
        # Check if node already exists
        db = get_db()
        cursor = db.cursor()
        cursor.execute("SELECT name FROM ai_workers WHERE name = ?", (f"rtx_{node_id}",))
        existing_node = cursor.fetchone()
        
        if existing_node:
            logger.info(f"Node {node_id} already registered, updating URL")
            cursor.execute(
                "UPDATE ai_workers SET address = ?, last_active = ? WHERE name = ?",
                (url, datetime.now().isoformat(), f"rtx_{node_id}")
            )
        else:
            # Add as new node - detect capabilities by checking endpoints
            async with aiohttp.ClientSession() as session:
                try:
                    # Health check
                    async with session.get(f"{url}/health", timeout=5) as response:
                        if response.status != 200:
                            raise HTTPException(status_code=400, detail="Node health check failed")
                    
                    # Check status to get supported models
                    async with session.get(f"{url}/status", timeout=5) as response:
                        if response.status == 200:
                            node_status = await response.json()
                            models = node_status.get("models", [])
                        else:
                            models = []
                            
                    # Map models to worker types
                    supported_types = set()
                    for model in models:
                        model_type = model.get("type", "")
                        if model_type:
                            supported_types.add(model_type)
                    
                    # Default to 'chat' if no types detected
                    node_type = list(supported_types)[0] if supported_types else "chat"
                    
                    # Insert the new worker
                    cursor.execute("""
                    INSERT INTO ai_workers (name, address, type, health_score, is_blacklisted, last_active)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, (f"rtx_{node_id}", url, node_type, 100.0, False, datetime.now().isoformat()))
                    
                    # If node supports multiple types, add additional entries
                    if len(supported_types) > 1:
                        for worker_type in list(supported_types)[1:]:
                            cursor.execute("""
                            INSERT INTO ai_workers (name, address, type, health_score, is_blacklisted, last_active)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """, (f"rtx_{node_id}_{worker_type}", url, worker_type, 100.0, False, datetime.now().isoformat()))
                    
                    logger.info(f"Added new RTX node: {node_id} with types {supported_types}")
                    
                except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                    logger.error(f"Error connecting to node: {str(e)}")
                    raise HTTPException(status_code=400, detail=f"Could not connect to node: {str(e)}")
        
        db.commit()
        db.close()
        
        # Broadcast worker update to all clients
        await manager.broadcast({
            "type": "sysop_message", 
            "message": f"New RTX node joined the neural mesh: rtx_{node_id}"
        })
        
        # Return success page
        html_content = f"""
        <!DOCTYPE html>
        <html>
        <head>
            <title>RENT-A-HAL: Node Added</title>
            <style>
                body {{ font-family: Arial, sans-serif; background-color: #1a1a1a; color: #f0f0f0; 
                       text-align: center; padding: 50px; }}
                .success {{ color: #4CAF50; font-size: 24px; margin-bottom: 20px; }}
                .details {{ background-color: #333; padding: 20px; border-radius: 10px; 
                          display: inline-block; text-align: left; }}
                a {{ color: #3498db; }}
            </style>
        </head>
        <body>
            <h1 class="success">RTX Node Successfully Added!</h1>
            <p>Your system is now part of the RENT-A-HAL neural mesh!</p>
            
            <div class="details">
                <p><strong>Node ID:</strong> rtx_{node_id}</p>
                <p><strong>Connection URL:</strong> {url}</p>
                <p><strong>Status:</strong> Active and ready for work</p>
            </div>
            
            <p style="margin-top: 30px;">
                You can close this window and return to your node application.
                <br><br>
                <a href="/">Return to RENT-A-HAL Home</a>
            </p>
        </body>
        </html>
        """
        
        return HTMLResponse(content=html_content)
    except Exception as e:
        logger.error(f"Error registering RTX node: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error registering node: {str(e)}")
