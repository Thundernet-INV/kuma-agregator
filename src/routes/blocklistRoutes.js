import { Router } from 'express';

const router = Router();

// Endpoint blocklist
router.get('/blocklist', (req, res) => {
  console.log('📋 Blocklist consultada');
  
  res.json({
    success: true,
    data: [],
    count: 0,
    timestamp: Date.now()
  });
});

export default router;
