import { Router } from 'express';
import { getHistory, getSeries, postEvent } from '../controllers/historyController.js';

const router = Router();

router.get('/', getHistory);
router.get('/series', getSeries);
router.post('/', postEvent); // Si no quieres POST, comenta esta línea

export default router;
