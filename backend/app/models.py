"""Versioned documents. Unknown optional fields survive load/save."""
from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal, Self
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from .migrations import MAX_REVISION, migrate_document

Unit = Annotated[float, Field(ge=0, le=1)]
PositiveUnit = Annotated[float, Field(gt=0, le=1)]
Color = Annotated[str, Field(pattern=r'^#[0-9a-fA-F]{6}$')]


class Model(BaseModel):
    model_config = ConfigDict(extra='allow', allow_inf_nan=False, strict=True)


class Point(Model):
    x: Unit
    y: Unit


class LineGeometry(Model):
    x1: Unit
    y1: Unit
    x2: Unit
    y2: Unit


class ArrowGeometry(LineGeometry):
    arrowheadSize: Annotated[float, Field(gt=0, le=0.5)] = 0.025


class RectangleGeometry(Model):
    x: Unit
    y: Unit
    width: PositiveUnit
    height: PositiveUnit

    @model_validator(mode='after')
    def bounds(self) -> Self:
        if self.x + self.width > 1.000001 or self.y + self.height > 1.000001:
            raise ValueError('Rectangle extends outside the video')
        return self


class EllipseGeometry(Model):
    centerX: Unit
    centerY: Unit
    radiusX: PositiveUnit
    radiusY: PositiveUnit

    @model_validator(mode='after')
    def bounds(self) -> Self:
        if (self.centerX - self.radiusX < -0.000001
                or self.centerY - self.radiusY < -0.000001
                or self.centerX + self.radiusX > 1.000001
                or self.centerY + self.radiusY > 1.000001):
            raise ValueError('Ellipse extends outside the video')
        return self


class FreehandGeometry(Model):
    points: Annotated[list[Point], Field(min_length=2, max_length=20000)]
    smoothing: Literal[0] = 0


class TextGeometry(Model):
    x: Unit
    y: Unit
    text: Annotated[str, Field(min_length=1, max_length=2000)]
    fontSize: Annotated[float, Field(gt=0, le=0.5)] = 0.04
    alignment: Literal['left', 'center', 'right'] = 'left'
    backgroundColor: Color = '#000000'
    backgroundOpacity: Unit = 0


class AnnotationBase(Model):
    id: str
    startSec: Annotated[float, Field(ge=0)]
    endSec: Annotated[float, Field(gt=0)]
    zIndex: Annotated[int, Field(ge=0, le=100000)]
    strokeColor: Color = '#ff3333'
    strokeWidth: Annotated[float, Field(gt=0, le=0.1)] = 0.006
    strokeOpacity: Unit = 1
    fillColor: Color = '#ff3333'
    fillOpacity: Unit = 0
    createdAt: str
    updatedAt: str

    @field_validator('id')
    @classmethod
    def valid_uuid(cls, value: str) -> str:
        if str(UUID(value)) != value:
            raise ValueError('Identifier must be a canonical UUID')
        return value

    @field_validator('createdAt', 'updatedAt')
    @classmethod
    def valid_date(cls, value: str) -> str:
        if datetime.fromisoformat(value.replace('Z', '+00:00')).tzinfo is None:
            raise ValueError('Timestamp must include a timezone')
        return value

    @model_validator(mode='after')
    def valid_interval(self) -> Self:
        if self.startSec >= self.endSec:
            raise ValueError('Annotation start must precede its end')
        return self


class Line(AnnotationBase):
    type: Literal['line']
    geometry: LineGeometry


class Arrow(AnnotationBase):
    type: Literal['arrow']
    geometry: ArrowGeometry


class Rectangle(AnnotationBase):
    type: Literal['rectangle']
    geometry: RectangleGeometry


class Ellipse(AnnotationBase):
    type: Literal['ellipse']
    geometry: EllipseGeometry


class Freehand(AnnotationBase):
    type: Literal['freehand']
    geometry: FreehandGeometry


class Text(AnnotationBase):
    type: Literal['text']
    geometry: TextGeometry


Annotation = Annotated[Line | Arrow | Rectangle | Ellipse | Freehand | Text,
                       Field(discriminator='type')]


class Media(Model):
    asset: str
    videoStartSec: float = 0
    videoStreamIndex: Annotated[int, Field(ge=0)] = 0
    audioStreamIndex: Annotated[int | None, Field(ge=0)] = None
    originalFilename: Annotated[str, Field(min_length=1, max_length=240)]
    durationSec: Annotated[float, Field(gt=0, le=86400)]
    codec: str
    audioCodec: str | None = None
    hasAudio: bool
    codedWidth: Annotated[int, Field(gt=0, le=32768)]
    codedHeight: Annotated[int, Field(gt=0, le=32768)]
    displayWidth: Annotated[int, Field(gt=0, le=32768)]
    displayHeight: Annotated[int, Field(gt=0, le=32768)]
    sampleAspectRatio: str
    displayAspectRatio: str
    rotation: float
    avgFrameRate: Annotated[float, Field(gt=0, le=1000)]

    @field_validator('asset')
    @classmethod
    def safe_asset(cls, value: str) -> str:
        from pathlib import PurePosixPath
        path = PurePosixPath(value)
        if (not value or path.is_absolute() or '\\' in value or ':' in value
                or any(p in ('.', '..', '') for p in value.split('/'))
                or '\x00' in value):
            raise ValueError('Asset must be a safe project-relative path')
        return value


class Settings(Model):
    defaultAnnotationDuration: Annotated[float, Field(gt=0, le=3600)] = 5
    seekStepSec: Annotated[float, Field(gt=0, le=60)] = 0.1
    largeSeekStepSec: Annotated[float, Field(gt=0, le=3600)] = 1
    originalAudioGain: Annotated[float, Field(ge=0, le=2)] = 1
    originalAudioMuted: bool = False
    voiceoverMasterGain: Annotated[float, Field(ge=0, le=2)] = 1


class ExportSettings(Model):
    fps: Annotated[float, Field(gt=0, le=120)] = 30
    crf: Annotated[int, Field(ge=0, le=40)] = 18
    preset: Literal['ultrafast', 'superfast', 'veryfast', 'faster', 'fast',
                    'medium', 'slow', 'slower', 'veryslow'] = 'medium'


class Voiceover(Model):
    id: str
    asset: str
    startSec: Annotated[float, Field(ge=0)]
    durationSec: Annotated[float, Field(gt=0)]
    endSec: Annotated[float, Field(gt=0)]
    gain: Annotated[float, Field(ge=0, le=2)] = 1
    muted: bool = False
    timingOffsetMs: Annotated[float, Field(ge=-60000, le=60000)] = 0
    recordedAt: str
    codec: str
    sampleRate: Annotated[int, Field(gt=0, le=384000)]
    channels: Annotated[int, Field(gt=0, le=8)]

    _uuid = field_validator('id')(AnnotationBase.valid_uuid.__func__)
    _asset = field_validator('asset')(Media.safe_asset.__func__)
    _date = field_validator('recordedAt')(AnnotationBase.valid_date.__func__)

    @model_validator(mode='after')
    def valid_interval(self) -> Self:
        if abs(self.startSec + self.durationSec - self.endSec) > 0.001:
            raise ValueError('Voiceover end must equal start plus duration')
        if self.startSec + self.timingOffsetMs / 1000 < 0:
            raise ValueError('Voiceover offset moves it before the video')
        return self


class Project(Model):
    schemaVersion: Literal[2] = 2
    revision: Annotated[int, Field(ge=1, le=MAX_REVISION, strict=True)] = 1
    requiredCapabilities: list[str] = Field(default_factory=lambda: ['project.revisions.v1'])
    projectId: str
    projectName: Annotated[str, Field(min_length=1, max_length=160)]
    createdAt: str
    updatedAt: str
    source: Media
    proxy: Media
    settings: Settings = Field(default_factory=Settings)
    exportSettings: ExportSettings = Field(default_factory=ExportSettings)
    annotations: Annotated[list[Annotation], Field(max_length=2000)] = Field(default_factory=list)
    voiceovers: Annotated[list[Voiceover], Field(max_length=200)] = Field(default_factory=list)

    _uuid = field_validator('projectId')(AnnotationBase.valid_uuid.__func__)
    _dates = field_validator('createdAt', 'updatedAt')(AnnotationBase.valid_date.__func__)

    @model_validator(mode='before')
    @classmethod
    def migrate(cls, value: object) -> object:
        # Constructors for a newly imported asset use current defaults; persisted
        # and client documents always carry a schema version.
        if isinstance(value, dict) and 'schemaVersion' not in value:
            value = {'schemaVersion': 2, 'revision': 1,
                     'requiredCapabilities': ['project.revisions.v1'], **value}
        return migrate_document(value)

    @model_validator(mode='after')
    def valid_project(self) -> Self:
        if not self.projectName.strip():
            raise ValueError('Enter a project name')
        identifiers = [a.id for a in self.annotations] + [v.id for v in self.voiceovers]
        if len(identifiers) != len(set(identifiers)):
            raise ValueError('Annotation and voiceover identifiers must be unique')
        if any(a.endSec > self.source.durationSec + 0.000001 for a in self.annotations):
            raise ValueError('Annotation extends past video duration')
        if any(v.endSec + v.timingOffsetMs / 1000 > self.source.durationSec + 0.001
               for v in self.voiceovers):
            raise ValueError('Voiceover extends past video duration')
        return self


class Job(Model):
    jobId: str
    projectId: str
    projectRevision: int | None = None
    retryOf: str | None = None
    retryAvailable: bool = False
    outputAvailable: bool = False
    errorCode: str | None = None
    status: Literal['queued', 'running', 'completed', 'failed', 'cancelled'] = 'queued'
    progress: Annotated[float, Field(ge=0, le=100)] = 0
    renderedSec: Annotated[float, Field(ge=0)] = 0
    error: str | None = None
    filename: str | None = None
    createdAt: str
