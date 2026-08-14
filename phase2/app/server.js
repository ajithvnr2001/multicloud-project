const express = require('express');
const { Pool } = require('pg');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8080;

const pool = new Pool({
  host: process.env.DB_HOST || '127.0.0.1',
  port: parseInt(process.env.DB_PORT || '5432', 10),
  database: process.env.DB_NAME || 'appdb',
  user: process.env.DB_USER || 'appuser',
  password: process.env.DB_PASS || 'password',
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

app.get('/', (req, res) => {
  res.json({
    status: "Healthy",
    message: "Welcome to Project 2 (GKE 3-Tier Architecture on GCP!)",
    timestamp: new Date(),
    version: process.env.K_REVISION || "2.0.0",
    tier: "Tier 2 Application API"
  });
});

app.get('/health', (req, res) => {
  res.status(200).json({ status: "UP", tier: "Tier 2" });
});

app.get('/db-health', async (req, res) => {
  try {
    const result = await pool.query('SELECT NOW() as db_time, current_database() as db_name');
    res.status(200).json({
      status: "CONNECTED",
      database: result.rows[0].db_name,
      timestamp: result.rows[0].db_time
    });
  } catch (err) {
    console.error('Database connection error:', err.message);
    res.status(500).json({
      status: "DISCONNECTED",
      error: err.message
    });
  }
});

app.get('/api/items', async (req, res) => {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS items (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);
    const result = await pool.query('SELECT * FROM items ORDER BY id DESC LIMIT 10');
    res.json({ success: true, count: result.rowCount, data: result.rows });
  } catch (err) {
    console.error('API Query error:', err.message);
    res.status(500).json({ success: false, error: err.message });
  }
});

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`Phase 2 Application API listening on port ${PORT}`);
});

module.exports = server;
