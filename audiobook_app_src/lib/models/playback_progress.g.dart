// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'playback_progress.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class PlaybackProgressAdapter extends TypeAdapter<PlaybackProgress> {
  @override
  final int typeId = 1;

  @override
  PlaybackProgress read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PlaybackProgress(
      bookId: fields[0] as String,
      chapterIndex: fields[1] as int,
      positionSeconds: fields[2] as int,
      updatedAt: fields[3] as DateTime?,
      bookTitle: fields[4] as String?,
      chapterCount: fields[5] as int?,
    );
  }

  @override
  void write(BinaryWriter writer, PlaybackProgress obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.bookId)
      ..writeByte(1)
      ..write(obj.chapterIndex)
      ..writeByte(2)
      ..write(obj.positionSeconds)
      ..writeByte(3)
      ..write(obj.updatedAt)
      ..writeByte(4)
      ..write(obj.bookTitle)
      ..writeByte(5)
      ..write(obj.chapterCount);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackProgressAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
