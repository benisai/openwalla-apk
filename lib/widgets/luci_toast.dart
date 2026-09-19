import 'package:flutter/material.dart';
import 'package:luci_mobile/widgets/openwalla_toast.dart';

extension LuciToastContext on BuildContext {
  void showToastLoading(String message, {String? subtitle, String? actionKey}) {
    OpenwallaToast.showLoading(
      this,
      key: actionKey ?? message,
      message: subtitle == null ? message : '$message\n$subtitle',
    );
  }

  void showToastSuccess(String message, {String? subtitle, String? actionKey}) {
    OpenwallaToast.showSuccess(
      this,
      key: actionKey ?? message,
      message: subtitle == null ? message : '$message\n$subtitle',
    );
  }

  void showToastError(String message, {String? subtitle, String? actionKey}) {
    OpenwallaToast.showError(
      this,
      key: actionKey ?? message,
      message: subtitle == null ? message : '$message\n$subtitle',
    );
  }

  void showToastInfo(String message, {String? subtitle, String? actionKey}) {
    showToastSuccess(message, subtitle: subtitle, actionKey: actionKey);
  }
}
