#!/usr/bin/env node
// scripts/generate-test-averages.js
// Genera datos de prueba para promedios de instancias

import { ensureSQLite } from '../src/services/storage/sqlite.js';
import * as historyService from '../src/services/historyService.js';

const INSTANCIAS = [
    'Caracas', 'Guanare', 'Barquisimeto', 'San Felipe', 'San Carlos',
    'Acarigua', 'Barinas', 'San Fernando', 'Chichiriviche', 'Tucacas'
];

async function generateTestData() {
    console.log('📊 Generando datos de prueba para promedios...');
    
    try {
        await ensureSQLite();
        
        const now = Date.now();
        const hourMs = 60 * 60 * 1000;
        
        // Generar datos para las últimas 24 horas
        for (let hour = 0; hour < 24; hour++) {
            const timestamp = now - (hour * hourMs);
            
            for (const instancia of INSTANCIAS) {
                // Crear entre 3-8 monitores por instancia
                const numMonitores = Math.floor(Math.random() * 5) + 3;
                
                for (let i = 0; i < numMonitores; i++) {
                    const monitorId = `${instancia}_Servicio_${i + 1}`;
                    const status = Math.random() > 0.1 ? 'up' : 'down';
                    const responseTime = status === 'up' ? 
                        Math.floor(Math.random() * 150) + 50 : 
                        -1;
                    
                    await historyService.addEvent({
                        monitorId,
                        timestamp: timestamp,
                        status,
                        responseTime: responseTime > 0 ? responseTime : null,
                        message: null
                    });
                }
            }
            
            if (hour % 6 === 0) {
                console.log(`  • Hora ${hour}: datos generados`);
            }
        }
        
        // Calcular promedios
        const { calculateAllInstanceAverages } = await import('../src/services/storage/sqlite.js');
        const results = await calculateAllInstanceAverages();
        
        console.log(`\n✅ Datos de prueba generados exitosamente`);
        console.log(`   • ${INSTANCIAS.length} instancias`);
        console.log(`   • ${results.length} promedios calculados`);
        
        process.exit(0);
    } catch (error) {
        console.error('❌ Error generando datos:', error);
        process.exit(1);
    }
}

generateTestData();
