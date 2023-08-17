{ lib
, buildPythonPackage
, fetchPypi
, distlib
, pythonOlder
, exceptiongroup
, hatch-vcs
, hatchling
, cattrs
, cmake
, ninja
, packaging
, pathspec
, pyproject-metadata
, pytest-subprocess
, pytestCheckHook
, setuptools
, tomli
, wheel
}:

buildPythonPackage rec {
  pname = "scikit-build-core";
  version = "0.2.0";
  format = "pyproject";

  src = fetchPypi {
    pname = "scikit_build_core";
    inherit version;
    hash = "sha256-0qdtlEekEgONxeJd0lmwPCUnhmGgx8Padmu5ccGprNI=";
  };

  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace 'minversion = "7.2"' "" \
      --replace '"error",' '"error", "ignore::DeprecationWarning", "ignore::UserWarning",'
  '';

  nativeBuildInputs = [
    hatch-vcs
    hatchling
  ];

  propagatedBuildInputs = [
    packaging
  ] ++ lib.optionals (pythonOlder "3.11") [
    exceptiongroup
    tomli
  ];

  passthru.optional-dependencies = {
    pyproject = [
      distlib
      pathspec
      pyproject-metadata
    ];
  };

  dontUseCmakeConfigure = true;

  nativeCheckInputs = [
    cattrs
    cmake
    ninja
    pytest-subprocess
    pytestCheckHook
    setuptools
    wheel
  ] ++ passthru.optional-dependencies.pyproject;

  disabledTestPaths = [
    # runs pip, requires network access
    "tests/test_pyproject_pep517.py"
    "tests/test_pyproject_pep518.py"
    "tests/test_setuptools_pep517.py"
    "tests/test_setuptools_pep518.py"
  ];

  pythonImportsCheck = [
    "scikit_build_core"
  ];

  meta = with lib; {
    description = "A next generation Python CMake adaptor and Python API for plugins";
    homepage = "https://github.com/scikit-build/scikit-build-core";
    license = with licenses; [ asl20 ];
    maintainers = with maintainers; [ veprbl ];
  };
}
