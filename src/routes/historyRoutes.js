// src/routes/historyRoutes.js
import { Router } from 'express';
import { getHistory, getSeries, postEvent } from '../controllers/historyController.js';

const router = Router();

router.get('/', getHistory);
router.get('/series', getSeries);
router.post('/', postEvent);

export default router;
