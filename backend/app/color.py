"""SDR delivery policy. Convert video before compositing sRGB drawing colors."""
from __future__ import annotations

from .errors import DomainError

HDR_CAPABILITY = 'media.hdr-to-sdr.v1'
HDR_TRANSFERS = {'smpte2084', 'arib-std-b67', 'SMPTE_ST_2084_PQ', 'ITU_R_2100_HLG'}
REC709_TAGS = ['-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv']


def is_hdr(media: dict) -> bool:
    return media.get('transferFunction') in HDR_TRANSFERS


def require_supported_color(media: dict) -> None:
    # Never guess a Dolby Vision profile or treat its dynamic metadata as SDR.
    if media.get('dolbyVision'):
        raise DomainError('MEDIA_UNSUPPORTED', 'This Dolby Vision variant needs a Photos-rendered SDR copy. Its original was preserved.', 422)
    if is_hdr(media) and (media.get('colorPrimaries') not in ('bt2020', 'ITU_R_2020')
                          or media.get('colorMatrix') not in ('bt2020nc', 'ITU_R_2020')
                          or media.get('colorRange') not in ('tv', 'pc')):
        raise DomainError('MEDIA_UNSUPPORTED', 'HDR needs valid Rec.2020 primaries, matrix and range metadata. Choose a complete original or an SDR copy.', 422)


def hdr_to_srgb(media: dict) -> str:
    """A deterministic 1000-nit nominal input, 100-nit SDR delivery transform.

    zscale linearizes PQ/HLG, then converts gamut. Mobius preserves dark contrast
    and compresses highlights. A fixed nominal peak avoids frame-to-frame pumping.
    The sRGB result shares the drawing compositor's transfer/primaries.
    """
    require_supported_color(media)
    if not is_hdr(media):
        return ''
    return ('zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,'
            'tonemap=tonemap=mobius:param=0.3:desat=2:peak=10,'
            'zscale=t=iec61966-2-1:r=full,format=gbrp,')


def srgb_to_rec709() -> str:
    return ('zscale=pin=bt709:tin=iec61966-2-1:min=gbr:rin=full:'
            'p=bt709:t=bt709:m=bt709:r=limited,format=yuv420p')
