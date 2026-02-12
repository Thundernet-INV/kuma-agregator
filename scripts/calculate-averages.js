#!/usr/bin/env node
// scripts/calculate-averages.js
// Script para calcular promedios de instancias manualmente

import { ensureSQLite, calculateAllInstanceAverages } from '../src/services/storage/sqlite.js';

async function main() {
    console.log('📊 Calculando promedios de instancias...');
    
    try {
        await ensureSQLite();
        const results = await calculateAllInstanceAverages();
        
        console.log(`✅ Promedios calculados para ${results.length} instancias`);
        
        if (results.length > 0) {
            console.log('\nResumen:');
            results.forEach(r => {
                console.log(`  • ${r.instance}: ${Math.round(r.avgResponseTime)}ms (${r.monitorCount} monitores)`);
            });
        }
        
        process.exit(0);
    } catch (error) {
        console.error('❌ Error:', error);
        process.exit(1);
    }
}

main();
