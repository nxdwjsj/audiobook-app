/// 一个待解析的夸克分享（书源发现渠道的输出契约）。
class ResourceHit {
  final String pwdId;
  final String? passcode;
  final String source;

  ResourceHit(this.pwdId, {this.passcode, this.source = 'manual'});

  String get url => 'https://pan.quark.cn/s/$pwdId';
}
