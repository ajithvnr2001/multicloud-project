const express = require('express');
const app = express();
const PORT = process.env.PORT || 8080;



app.get('/', (req, res) => {
  res.json({
    status: "Healthy",
    message: "Welcome to Project 1 on GCP!",
    timestamp: new Date(),
    version: process.env.K_REVISION || "local"
  });
});

// Explicit health check endpoint for Cloud Run Startup/Liveness probe
app.get('/health', (req, res) => {
  res.status(200).json({ status: "UP" });
});

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`Application listening on port ${PORT}`);
});

module.exports = server;
