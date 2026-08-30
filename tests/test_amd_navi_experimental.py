import unittest

from unittest.mock import patch

from opencore_legacy_patcher import constants
from opencore_legacy_patcher.detections import device_probe
from opencore_legacy_patcher.sys_patch.patchsets import detect
from opencore_legacy_patcher.sys_patch.patchsets.hardware.graphics import amd_navi


def amd(device_id: int, class_code: int | None = 0x030000) -> device_probe.AMD:
    return device_probe.AMD(
        vendor_id=0x1002,
        device_id=device_id,
        class_code=class_code,
        name=f"GFX{device_id:04X}",
        model="AMD test GPU",
        pci_path="PciRoot(0x0)/Pci(0x1,0x0)",
    )


def navi_detector(
    *,
    model: str = "MacPro6,1",
    gpus: list[device_probe.AMD] | None = None,
    cpu_leafs: list[str] | None = None,
    xnu_major: int = 24,
    os_build: str = "24G830",
) -> amd_navi.AMDNavi:
    global_constants = constants.Constants()
    global_constants.computer = device_probe.Computer(
        real_model=model,
        gpus=gpus or [amd(0x6798), amd(0x6798), amd(0x731F)],
        cpu=device_probe.CPU(name="Xeon E5-2697 v2", flags=["AVX1.0"], leafs=cpu_leafs or []),
    )
    return amd_navi.AMDNavi(xnu_major, 0, os_build, global_constants)


class TestAMDNaviExperimentalEligibility(unittest.TestCase):
    def test_present_accepts_only_the_exact_developer_enabled_profile(self):
        detector = navi_detector()

        with patch.object(detector, "_dortania_internal_check", return_value=True):
            self.assertTrue(detector.present())

    def test_present_rejects_each_required_exact_profile_mismatch(self):
        cases = {
            "wrong model": {"model": "MacPro5,1"},
            "extra non-skipped GPU": {"gpus": [amd(0x6798), amd(0x6798), amd(0x731F), amd(0x67DF)]},
            "wrong Navi device": {"gpus": [amd(0x6798), amd(0x6798), amd(0x7310)]},
            "AVX2 CPU": {"cpu_leafs": ["AVX2"]},
            "wrong Darwin major": {"xnu_major": 23},
            "wrong build": {"os_build": "24G829"},
        }

        for name, kwargs in cases.items():
            with self.subTest(name=name):
                detector = navi_detector(**kwargs)
                with patch.object(detector, "_dortania_internal_check", return_value=True):
                    self.assertFalse(detector.present())

    def test_present_ignores_missing_and_placeholder_gpu_entries(self):
        detector = navi_detector(gpus=[
            amd(0x6798),
            amd(0x6798),
            amd(0x731F),
            amd(0x67DF, class_code=None),
            amd(0x67DF, class_code=0xFFFFFFFF),
        ])

        with patch.object(detector, "_dortania_internal_check", return_value=True):
            self.assertTrue(detector.present())

    def test_present_requires_the_existing_developer_sentinel(self):
        detector = navi_detector()

        with patch.object(detector, "_dortania_internal_check", return_value=False):
            self.assertFalse(detector.present())

    def test_detector_registers_navi_immediately_after_legacy_gcn(self):
        with patch.object(detect.HardwarePatchsetDetection, "_detect", return_value=None):
            detector = detect.HardwarePatchsetDetection(navi_detector()._constants)

        variants = detector._hardware_variants
        navi_index = variants.index(amd_navi.AMDNavi)
        self.assertEqual(variants[navi_index - 1].__name__, "AMDLegacyGCN")
        self.assertEqual(variants[navi_index + 1].__name__, "AMDPolaris")


if __name__ == "__main__":
    unittest.main()
