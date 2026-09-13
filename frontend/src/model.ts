import { z } from 'zod';
import { migrateDocument } from './project/migrations';

const number = z.number().finite();
const coordinate = number.min(0).max(1);
const color = z.string().regex(/^#[0-9a-fA-F]{6}$/);
const opacity = number.min(0).max(1);
const uuid = z
  .string()
  .uuid()
  .refine((value) => value === value.toLowerCase(), 'Identifier must be a canonical UUID');
const timestamp = z.string().datetime({ offset: true });
const asset = z
  .string()
  .min(1)
  .refine(
    (value) =>
      !value.startsWith('/') &&
      !value.includes('\\') &&
      !value
        .split('/')
        .some(
          (part) =>
            part === '..' ||
            part === '.' ||
            part === '' ||
            part.includes(':') ||
            part.includes('\0'),
        ),
    'Asset must be a safe project-relative reference',
  );

export const mediaSchema = z
  .object({
    asset,
    originalFilename: z.string().min(1).max(240),
    durationSec: number.positive().max(86400),
    codec: z.string(),
    audioCodec: z.string().nullable(),
    hasAudio: z.boolean(),
    codedWidth: number.int().positive().max(32768),
    codedHeight: number.int().positive().max(32768),
    displayWidth: number.int().positive().max(32768),
    displayHeight: number.int().positive().max(32768),
    sampleAspectRatio: z.string(),
    displayAspectRatio: z.string(),
    rotation: number,
    avgFrameRate: number.positive().max(1000),
    transferFunction: z.string().min(1).max(100).nullable().optional(),
    colorPrimaries: z.string().min(1).max(100).nullable().optional(),
    colorMatrix: z.string().min(1).max(100).nullable().optional(),
    colorRange: z.string().min(1).max(100).nullable().optional(),
    dolbyVision: z.boolean().nullable().optional(),
    averageFrameRateRational: z.string().min(1).max(100).nullable().optional(),
    nominalFrameRateRational: z.string().min(1).max(100).nullable().optional(),
    timeBase: z.string().min(1).max(100).nullable().optional(),
  })
  .passthrough();

const annotationBase = {
  id: uuid,
  startSec: number.min(0),
  endSec: number.positive(),
  zIndex: number.int().min(0).max(100000),
  strokeColor: color,
  strokeWidth: number.positive().max(0.1),
  strokeOpacity: opacity,
  fillColor: color,
  fillOpacity: opacity,
  createdAt: timestamp,
  updatedAt: timestamp,
};
const endpoints = { x1: coordinate, y1: coordinate, x2: coordinate, y2: coordinate };
export const annotationSchema = z
  .discriminatedUnion('type', [
    z
      .object({
        ...annotationBase,
        type: z.literal('line'),
        geometry: z.object(endpoints).passthrough(),
      })
      .passthrough(),
    z
      .object({
        ...annotationBase,
        type: z.literal('arrow'),
        geometry: z
          .object({ ...endpoints, arrowheadSize: number.positive().max(0.5) })
          .passthrough(),
      })
      .passthrough(),
    z
      .object({
        ...annotationBase,
        type: z.literal('rectangle'),
        geometry: z
          .object({
            x: coordinate,
            y: coordinate,
            width: coordinate.positive(),
            height: coordinate.positive(),
          })
          .passthrough()
          .refine(
            (g) => g.x + g.width <= 1.000001 && g.y + g.height <= 1.000001,
            'Rectangle must fit inside video',
          ),
      })
      .passthrough(),
    z
      .object({
        ...annotationBase,
        type: z.literal('ellipse'),
        geometry: z
          .object({
            centerX: coordinate,
            centerY: coordinate,
            radiusX: coordinate.positive(),
            radiusY: coordinate.positive(),
          })
          .passthrough()
          .refine(
            (g) =>
              g.centerX - g.radiusX >= -0.000001 &&
              g.centerY - g.radiusY >= -0.000001 &&
              g.centerX + g.radiusX <= 1.000001 &&
              g.centerY + g.radiusY <= 1.000001,
            'Ellipse must fit inside video',
          ),
      })
      .passthrough(),
    z
      .object({
        ...annotationBase,
        type: z.literal('freehand'),
        geometry: z
          .object({
            points: z
              .array(z.object({ x: coordinate, y: coordinate }).passthrough())
              .min(2)
              .max(20000),
            smoothing: z.literal(0),
          })
          .passthrough(),
      })
      .passthrough(),
    z
      .object({
        ...annotationBase,
        type: z.literal('text'),
        geometry: z
          .object({
            x: coordinate,
            y: coordinate,
            text: z.string().min(1).max(2000),
            fontSize: number.positive().max(0.5),
            alignment: z.enum(['left', 'center', 'right']),
            backgroundColor: color,
            backgroundOpacity: opacity,
          })
          .passthrough(),
      })
      .passthrough(),
  ])
  .refine((a) => a.startSec < a.endSec, 'Annotation must have a positive duration');

export const voiceoverSchema = z
  .object({
    id: uuid,
    asset,
    startSec: number.min(0),
    durationSec: number.positive(),
    endSec: number.positive(),
    gain: number.min(0).max(2),
    muted: z.boolean(),
    timingOffsetMs: number.min(-60000).max(60000),
    recordedAt: timestamp,
    codec: z.string(),
    sampleRate: number.int().positive().max(384000),
    channels: number.int().min(1).max(8),
  })
  .passthrough()
  .refine(
    (v) => Math.abs(v.endSec - v.startSec - v.durationSec) < 0.001,
    'Voiceover end must match start + duration',
  );

const currentProjectSchema = z
  .object({
    schemaVersion: z.literal(2),
    revision: number.int().min(1).max(Number.MAX_SAFE_INTEGER),
    requiredCapabilities: z.array(z.string().min(1).max(100)).max(128),
    projectId: uuid,
    projectName: z.string().trim().min(1).max(160),
    createdAt: timestamp,
    updatedAt: timestamp,
    source: mediaSchema,
    proxy: mediaSchema,
    settings: z
      .object({
        defaultAnnotationDuration: number.positive().max(3600),
        seekStepSec: number.positive().max(60),
        largeSeekStepSec: number.positive().max(3600),
        originalAudioGain: number.min(0).max(2),
        originalAudioMuted: z.boolean(),
        voiceoverMasterGain: number.min(0).max(2),
      })
      .passthrough(),
    exportSettings: z
      .object({
        fps: number.positive().max(120),
        crf: number.int().min(0).max(40),
        preset: z.enum([
          'ultrafast',
          'superfast',
          'veryfast',
          'faster',
          'fast',
          'medium',
          'slow',
          'slower',
          'veryslow',
        ]),
      })
      .passthrough(),
    annotations: z.array(annotationSchema).max(2000),
    voiceovers: z.array(voiceoverSchema).max(200),
  })
  .passthrough()
  .superRefine((project, context) => {
    if (
      ['smpte2084', 'arib-std-b67', 'SMPTE_ST_2084_PQ', 'ITU_R_2100_HLG'].includes(
        project.source.transferFunction ?? '',
      ) &&
      !project.requiredCapabilities.includes('media.hdr-to-sdr.v1')
    )
      context.addIssue({
        code: 'custom',
        path: ['requiredCapabilities'],
        message: 'The HDR delivery capability is missing',
      });
    const ids = new Set<string>();
    for (const [index, item] of project.annotations.entries()) {
      if (item.endSec > project.source.durationSec + 0.000001)
        context.addIssue({
          code: 'custom',
          path: ['annotations', index, 'endSec'],
          message: 'Annotation ends after the video',
        });
      if (ids.has(item.id))
        context.addIssue({
          code: 'custom',
          path: ['annotations', index, 'id'],
          message: 'Duplicate identifier',
        });
      ids.add(item.id);
    }
    for (const [index, item] of project.voiceovers.entries()) {
      if (
        item.startSec + item.timingOffsetMs / 1000 < 0 ||
        item.endSec + item.timingOffsetMs / 1000 > project.source.durationSec + 0.001
      )
        context.addIssue({
          code: 'custom',
          path: ['voiceovers', index],
          message: 'Voiceover must fit the video timeline',
        });
      if (ids.has(item.id))
        context.addIssue({
          code: 'custom',
          path: ['voiceovers', index, 'id'],
          message: 'Duplicate identifier',
        });
      ids.add(item.id);
    }
  });

export const projectSchema = z.preprocess((value, context) => {
  try {
    return migrateDocument(value);
  } catch (error) {
    context.addIssue({
      code: 'custom',
      message: error instanceof Error ? error.message : 'Invalid project',
    });
    return z.NEVER;
  }
}, currentProjectSchema);

/** Boundary parsing retains typed upgrade errors for the project browser. */
export const readProject = (value: unknown) => currentProjectSchema.parse(migrateDocument(value));

export type Media = z.infer<typeof mediaSchema>;
export type Annotation = z.infer<typeof annotationSchema>;
export type Voiceover = z.infer<typeof voiceoverSchema>;
export type Project = z.infer<typeof projectSchema>;
export type Tool = 'select' | Annotation['type'];

export function isVisible(
  annotation: Pick<Annotation, 'startSec' | 'endSec'>,
  mediaTime: number,
): boolean {
  return annotation.startSec <= mediaTime && mediaTime < annotation.endSec;
}

export function annotationInterval(
  time: number,
  duration: number,
  defaultDuration = 5,
): { startSec: number; endSec: number } {
  const startSec = Math.max(0, Math.min(time, Math.max(0, duration - 0.001)));
  return { startSec, endSec: Math.min(duration, startSec + defaultDuration) };
}
