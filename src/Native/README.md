# Native receiver

受信エンジンは `third_party/UxPlay` の固定コミットを直接 CMake + Ninja でビルドする。
このディレクトリは今後のプロセス制御・IPCなどの統合層用。今回、UxPlay本体の改変や
WPFへの映像埋め込みは行わない。WindowsはUCRT64、macOSはHomebrew + Apple Clang。
ビルド成果物とログは `build/native/<OS>` と `artifacts/logs`。
