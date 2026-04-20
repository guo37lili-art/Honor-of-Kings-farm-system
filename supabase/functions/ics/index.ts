// Supabase Edge Function: 动态生成某个 crop 的 .ics 订阅
// URL: https://<project>.supabase.co/functions/v1/ics?crop_id=<id>&path=<fast|lazy|natural>
// 订阅: webcal://<project>.supabase.co/functions/v1/ics?crop_id=<id>&path=<fast|lazy|natural>
//
// 每次日历 App 刷新都会重新访问，自动反映最新 water_events / harvested_at 状态
//
// 部署：supabase functions deploy ics --no-verify-jwt

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const HOUR_MS = 3600 * 1000;

// ========== 核心算法（必须与 index.html 完全一致）==========

function computeMatTime(crop: any): number {
  const T = crop.type * HOUR_MS;
  const planted = new Date(crop.planted_at).getTime();
  const waters = (crop.water_events || []).map((t: string) => new Date(t).getTime());
  if (waters.length === 0) return planted + T;
  let reduction = T / 12;
  for (let i = 1; i < waters.length; i++) {
    const gap = waters[i] - waters[i - 1];
    const d = Math.max(0, Math.min(1, 3 * gap / T));
    reduction += d * T / 12;
  }
  reduction = Math.min(reduction, T);
  return planted + T - reduction;
}

function cooldownMs(crop: any): number {
  return crop.type * HOUR_MS / 30;
}

function computeWindowB(crop: any): number {
  const T = crop.type * HOUR_MS;
  const planted = new Date(crop.planted_at).getTime();
  const waters = (crop.water_events || []).map((t: string) => new Date(t).getTime());
  const lastEvent = waters.length > 0 ? waters[waters.length - 1] : planted;
  const currentMat = computeMatTime(crop);
  const tauA = (4 * currentMat + lastEvent) / 5;
  let rawB;
  if (tauA < lastEvent + T / 3) {
    rawB = tauA;
  } else {
    rawB = Math.max(lastEvent + T / 3, currentMat - T / 12);
  }
  if (waters.length > 0) {
    return Math.max(rawB, lastEvent + cooldownMs(crop));
  }
  return rawB;
}

function computeWindowA(crop: any, now: number): number {
  const T = crop.type * HOUR_MS;
  const planted = new Date(crop.planted_at).getTime();
  const waters = (crop.water_events || []).map((t: string) => new Date(t).getTime());
  if (waters.length === 0) return now;
  const lastEvent = waters[waters.length - 1];
  const deadline = lastEvent + T / 3;
  const currentMat = computeMatTime(crop);
  const windowB = computeWindowB(crop);
  return Math.min(deadline, currentMat, windowB);
}

function computePredictedFastMat(crop: any, now: number): number {
  const T = crop.type * HOUR_MS;
  const planted = new Date(crop.planted_at).getTime();
  const waters = (crop.water_events || []).map((t: string) => new Date(t).getTime());
  const currentMat = computeMatTime(crop);
  let baseFormula, waste = 0;
  if (waters.length === 0) {
    const effectiveMat = (planted + T) - T / 12;
    baseFormula = (4 * effectiveMat + now) / 5;
  } else {
    const lastEvent = waters[waters.length - 1];
    baseFormula = (4 * currentMat + lastEvent) / 5;
    waste = Math.max(0, now - lastEvent - T / 3);
  }
  const predicted = baseFormula + waste / 5;
  return Math.max(now, Math.min(predicted, currentMat));
}

// ========== .ics 生成 ==========

function formatIcsDate(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`;
}

function escapeIcs(s: string): string {
  return String(s).replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/,/g, '\\,').replace(/;/g, '\\;');
}

interface IcsEvent {
  uid: string;
  start: number;
  end?: number;
  summary: string;
  description?: string;
  alarmMin?: number;
}

function generateIcs(calName: string, events: IcsEvent[]): string {
  const lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//王者农场助手//CN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    `X-WR-CALNAME:${escapeIcs(calName)}`,
    // 提示客户端每小时刷新一次
    'REFRESH-INTERVAL;VALUE=DURATION:PT1H',
    'X-PUBLISHED-TTL:PT1H',
  ];
  for (const e of events) {
    const endMs = e.end ?? (e.start + 5 * 60 * 1000);
    lines.push('BEGIN:VEVENT');
    lines.push(`UID:${e.uid}`);
    lines.push(`DTSTAMP:${formatIcsDate(Date.now())}`);
    lines.push(`DTSTART:${formatIcsDate(e.start)}`);
    lines.push(`DTEND:${formatIcsDate(endMs)}`);
    lines.push(`SUMMARY:${escapeIcs(e.summary)}`);
    if (e.description) lines.push(`DESCRIPTION:${escapeIcs(e.description)}`);
    if (typeof e.alarmMin === 'number' && e.alarmMin > 0) {
      lines.push('BEGIN:VALARM');
      lines.push('ACTION:DISPLAY');
      lines.push(`TRIGGER:-PT${e.alarmMin}M`);
      lines.push(`DESCRIPTION:${escapeIcs(e.summary)}`);
      lines.push('END:VALARM');
    }
    lines.push('END:VEVENT');
  }
  lines.push('END:VCALENDAR');
  return lines.join('\r\n');
}

// ========== 事件生成（按 path）==========

function eventsForPath(crop: any, path: string): IcsEvent[] {
  const cropLabel = `${crop.type}h 作物`;
  const now = Date.now();
  const cropIdShort = crop.id.slice(0, 8);

  if (path === 'fast') {
    const predictedFastMat = computePredictedFastMat(crop, now);
    const waters = (crop.water_events || []).map((t: string) => new Date(t).getTime());
    const waterNow = waters.length === 0;
    const windowA = computeWindowA(crop, now);
    const windowB = computeWindowB(crop);
    const windowAMissed = !waterNow && windowA < now - 1000;
    const shouldWaterNow = waterNow || windowAMissed;
    const fastConverged = !waterNow && Math.abs(windowA - windowB) < 1000;

    if (shouldWaterNow) {
      return [{
        uid: `fast-now-${cropIdShort}@wz-farm`,
        start: now + 60 * 1000,
        summary: `🔥 立刻浇水：${cropLabel}`,
        description: '越早浇水越接近最快路径最优解',
      }];
    } else if (fastConverged) {
      return [{
        uid: `fast-mature-${cropIdShort}@wz-farm`,
        start: windowA,
        summary: `🌾 浇水即熟：${cropLabel}`,
        description: '此时浇水立即成熟可收',
        alarmMin: 5,
      }];
    } else {
      return [{
        uid: `fast-deadline-${cropIdShort}@wz-farm`,
        start: windowA,
        summary: `🏃 下次浇水截止：${cropLabel}`,
        description: '在此时刻前完成下次浇水以保持最快路径',
        alarmMin: 10,
      }];
    }
  }

  if (path === 'lazy') {
    const windowB = computeWindowB(crop);
    return [{
      uid: `lazy-${cropIdShort}@wz-farm`,
      start: windowB,
      summary: `💤 浇水即熟：${cropLabel}`,
      description: '此时浇一次水立即成熟可收',
      alarmMin: 5,
    }];
  }

  // natural
  const matMs = computeMatTime(crop);
  return [{
    uid: `natural-${cropIdShort}@wz-farm`,
    start: matMs,
    summary: `🌱 自然成熟：${cropLabel}`,
    description: '作物自然成熟，可直接收获',
    alarmMin: 5,
  }];
}

// ========== HTTP handler ==========

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': '*',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: CORS_HEADERS });
  }

  const url = new URL(req.url);
  const cropId = url.searchParams.get('crop_id');
  const path = url.searchParams.get('path') || 'fast';

  if (!cropId) {
    return new Response('missing crop_id', { status: 400, headers: CORS_HEADERS });
  }
  if (!['fast', 'lazy', 'natural'].includes(path)) {
    return new Response('invalid path', { status: 400, headers: CORS_HEADERS });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  if (!supabaseUrl || !anonKey) {
    return new Response('server misconfigured', { status: 500, headers: CORS_HEADERS });
  }

  const supabase = createClient(supabaseUrl, anonKey);
  const { data: crop, error } = await supabase
    .from('crops')
    .select('*')
    .eq('id', cropId)
    .single();

  if (error || !crop) {
    // 作物不存在 → 返回空日历（让订阅失效但不报错）
    const content = generateIcs('作物已不存在', []);
    return new Response(content, {
      status: 200,
      headers: {
        ...CORS_HEADERS,
        'Content-Type': 'text/calendar; charset=utf-8',
      },
    });
  }

  // 已收获 → 空日历
  if (crop.harvested_at) {
    const content = generateIcs(`${crop.type}h 作物（已收获）`, []);
    return new Response(content, {
      status: 200,
      headers: {
        ...CORS_HEADERS,
        'Content-Type': 'text/calendar; charset=utf-8',
      },
    });
  }

  const events = eventsForPath(crop, path);
  const pathLabel = path === 'fast' ? '最快' : path === 'lazy' ? '懒人' : '自然';
  const content = generateIcs(`${pathLabel}·${crop.type}h 作物`, events);

  return new Response(content, {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      'Content-Type': 'text/calendar; charset=utf-8',
      'Content-Disposition': `inline; filename="farm-${path}-${cropId.slice(0, 8)}.ics"`,
      'Cache-Control': 'public, max-age=300',
    },
  });
});
