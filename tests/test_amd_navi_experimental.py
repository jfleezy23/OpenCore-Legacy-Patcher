import unittest
import warnings

from unittest.mock import patch

from opencore_legacy_patcher import constants
from opencore_legacy_patcher.detections import device_probe
from opencore_legacy_patcher.sys_patch.patchsets import detect
from opencore_legacy_patcher.sys_patch.patchsets.base import PatchType
from opencore_legacy_patcher.sys_patch.patchsets.hardware.graphics import amd_navi


IVY_BRIDGE_LEAF7_FEATURES = ["RDWRFSGS", "SMEP", "ERMS", "MDCLEAR", "IBRS", "STIBP", "L1DF", "SSBD"]
TARGET_CPU_NAME = "Intel(R) Xeon(R) CPU E5-2697 v2 @ 2.70GHz"


def amd(
    device_id: int | None,
    class_code: int | None = 0x030000,
    vendor_id: int | None = 0x1002,
) -> device_probe.AMD:
    return device_probe.AMD(
        vendor_id=vendor_id,
        device_id=device_id,
        class_code=class_code,
        name=f"GFX{device_id or 0:04X}",
        model="AMD test GPU",
        pci_path="PciRoot(0x0)/Pci(0x1,0x0)",
    )


def navi_detector(
    *,
    model: str = "MacPro6,1",
    gpus: list[device_probe.AMD] | None = None,
    cpu_name: str = TARGET_CPU_NAME,
    cpu_flags: list[str] | None = None,
    cpu_leafs: list[str] | None = None,
    xnu_major: int = 24,
    os_build: str = "24G830",
) -> amd_navi.AMDNavi:
    global_constants = constants.Constants()
    global_constants.detected_os_version = "15.7.9"
    if gpus is None:
        gpus = [amd(0x6798), amd(0x6798), amd(0x731F)]
    if cpu_leafs is None:
        cpu_leafs = IVY_BRIDGE_LEAF7_FEATURES
    if cpu_flags is None:
        cpu_flags = ["AVX1.0"]
    global_constants.computer = device_probe.Computer(
        real_model=model,
        gpus=gpus,
        cpu=device_probe.CPU(name=cpu_name, flags=cpu_flags, leafs=cpu_leafs),
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
            "no GPUs": {"gpus": []},
            "wrong Navi device": {"gpus": [amd(0x6798), amd(0x6798), amd(0x7310)]},
            "wrong CPU brand": {"cpu_name": "Intel(R) Xeon(R) CPU E5-2697 v2 @ 2.60GHz"},
            "missing AVX1.0": {"cpu_flags": []},
            "AVX2 CPU": {"cpu_leafs": ["AVX2"]},
            "wrong Darwin major": {"xnu_major": 23},
            "wrong build": {"os_build": "24G829"},
        }

        for name, kwargs in cases.items():
            with self.subTest(name=name):
                detector = navi_detector(**kwargs)
                with patch.object(detector, "_dortania_internal_check", return_value=True):
                    self.assertFalse(detector.present())

    def test_present_rejects_missing_or_unproven_cpu_leafs(self):
        cases = {
            "CPU not probed": lambda detector: setattr(detector._computer, "cpu", None),
            "empty leaf-7 data": lambda detector: setattr(detector._computer.cpu, "leafs", []),
            "invalid leaf-7 data": lambda detector: setattr(detector._computer.cpu, "leafs", None),
        }

        for name, mutate in cases.items():
            with self.subTest(name=name):
                detector = navi_detector()
                mutate(detector)
                with patch.object(detector, "_dortania_internal_check", return_value=True):
                    self.assertFalse(detector.present())

    def test_present_rejects_non_skipped_gpu_without_pci_identifiers(self):
        cases = {
            "missing vendor ID": [amd(0x6798), amd(0x6798), amd(0x731F, vendor_id=None)],
            "missing device ID": [amd(0x6798), amd(0x6798), amd(None)],
        }

        for name, gpus in cases.items():
            with self.subTest(name=name):
                detector = navi_detector(gpus=gpus)
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


class TestAMDNaviExperimentalPatchGraph(unittest.TestCase):
    def test_exact_darwin_24_operation_graph(self):
        expected = [
            ("Revert Monterey GVA", PatchType.REMOVE_SYSTEM_VOLUME, "/System/Library/PrivateFrameworks/AppleGVA.framework/Versions/A", "AppleGVA", None),
            ("Revert Monterey GVA", PatchType.REMOVE_SYSTEM_VOLUME, "/System/Library/PrivateFrameworks/AppleGVACore.framework/Versions/A", "AppleGVACore", None),
            ("Monterey OpenCL", PatchType.MERGE_SYSTEM_VOLUME, "/System/Library/Frameworks", "OpenCL.framework", "12.5"),
            ("AMD OpenCL", PatchType.MERGE_SYSTEM_VOLUME, "/System/Library/Frameworks", "OpenCL.framework", "12.5 non-AVX2.0"),
            ("AMD OpenCL", PatchType.MERGE_SYSTEM_VOLUME, "/System/Library/Frameworks", "OpenGL.framework", "12.5 non-AVX2.0"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMD7000Controller.kext", "12.5"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMD8000Controller.kext", "12.5"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMD9000Controller.kext", "12.5"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMD9500Controller.kext", "12.5"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMD10000Controller.kext", "12.5"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDRadeonX4000.kext", "12.5-23.4"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDRadeonX4000HWServices.kext", "12.5"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDFramebuffer.kext", "12.5-GCN"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDSupport.kext", "12.5"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDRadeonVADriver.bundle", "12.5"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDRadeonVADriver2.bundle", "12.5"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDRadeonX4000GLDriver.bundle", "12.5"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDMTLBronzeDriver.bundle", "12.5-24"),
            ("AMD Legacy GCN", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDShared.bundle", "12.5"),
            ("AMD Navi", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDRadeonX6000.kext", "12.5-23.4"),
            ("AMD Navi", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDRadeonX6000Framebuffer.kext", "12.5"),
            ("AMD Navi", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDRadeonVADriver2.bundle", "12.5"),
            ("AMD Navi", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDRadeonX6000GLDriver.bundle", "12.5"),
            ("AMD Navi", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDRadeonX6000MTLDriver.bundle", "12.5-24"),
            ("AMD Navi", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDRadeonX6000Shared.bundle", "12.5"),
            ("AMD Navi", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDShared.bundle", "12.5"),
            ("AMD Navi Extended", PatchType.OVERWRITE_SYSTEM_VOLUME, "/System/Library/Extensions", "AMDRadeonX6000HWServices.kext", "12.5"),
        ]

        with warnings.catch_warnings():
            warnings.simplefilter("ignore", ResourceWarning)
            with patch.object(amd_navi.AMDNavi, "_dortania_internal_check", return_value=True):
                detector = detect.HardwarePatchsetDetection(
                    navi_detector()._constants,
                    xnu_major=24,
                    xnu_minor=0,
                    os_build="24G830",
                )

        actual = []
        for patchset, patch_types in detector.patches.items():
            for patch_type, destinations in patch_types.items():
                for destination, items in destinations.items():
                    if patch_type is PatchType.REMOVE_SYSTEM_VOLUME:
                        actual.extend((patchset, patch_type, destination, item, None) for item in items)
                    else:
                        actual.extend((patchset, patch_type, destination, item, source) for item, source in items.items())

        self.assertEqual(len(actual), 27)
        self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
