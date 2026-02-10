// src/utils/validate.js
export function ensureEnv(key, fallback = undefined) {
    return process.env[key] ?? fallback;
}

export function assertQuery(params) {
    const errors = [];
    const { monitorId, from, to, limit, offset, bucketMs } = params;
    
    if (!monitorId || typeof monitorId !== 'string') errors.push('monitorId requerido');
    if (!from || isNaN(Number(from))) errors.push('from inválido (epoch ms)');
    if (!to || isNaN(Number(to))) errors.push('to inválido (epoch ms)');
    
    if (limit !== undefined && (isNaN(Number(limit)) || Number(limit) < 1 || Number(limit) > 10000)) {
        errors.push('limit debe ser 1-10000');
    }
    
    if (offset !== undefined && (isNaN(Number(offset)) || Number(offset) < 0)) {
        errors.push('offset debe ser >= 0');
    }
    
    if (bucketMs !== undefined && (isNaN(Number(bucketMs)) || Number(bucketMs) < 1000)) {
        errors.push('bucketMs debe ser >= 1000');
    }
    
    return errors;
}
