import 'package:flutter/material.dart';

class ImportMenuButton extends StatelessWidget {
  const ImportMenuButton(
      {super.key,
      required this.label,
      required this.onSelected,
      this.enabled = true});
  final String label;
  final ValueChanged<String> onSelected;
  final bool enabled;
  @override
  Widget build(BuildContext context) => MenuAnchor(
          menuChildren: [
            for (final entry in const [
              ('qr', '二维码', Icons.qr_code_2),
              ('file', '文件', Icons.upload_file_outlined),
              ('link', '链接', Icons.link),
              ('clipboard', '剪贴板 / 文本', Icons.content_paste),
              ('custom', '自定义', Icons.tune)
            ])
              MenuItemButton(
                  leadingIcon: Icon(entry.$3, size: 19),
                  onPressed: () => onSelected(entry.$1),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 8, horizontal: 10),
                      child: Text(entry.$2)))
          ],
          builder: (context, controller, child) => FilledButton.icon(
              onPressed: enabled
                  ? () {
                      if (controller.isOpen)
                        controller.close();
                      else
                        controller.open();
                    }
                  : null,
              icon: const Icon(Icons.add, size: 16),
              label: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(label),
                const SizedBox(width: 6),
                const Icon(Icons.expand_more, size: 16)
              ])));
}
