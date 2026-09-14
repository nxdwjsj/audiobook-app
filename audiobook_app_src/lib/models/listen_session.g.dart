// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'listen_session.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ListenSessionAdapter extends TypeAdapter<ListenSession> {
  @override
  final int typeId = 3;

  @override
  ListenSession read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ListenSession(
      id: fields[0] as String,
      bookId: fields[1] as String,
      bookTitle: fields[2] as String,
      startedAt: fields[3] as DateTime,
      updatedAt: fields[4] as DateTime,
      chapterIndex: fields[5] as int,
      positionSeconds: fields[6] as int,
      chapterCount: fields[7] as int?,
      chapterTitle: fields[8] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, ListenSession obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.bookId)
      ..writeByte(2)
      ..write(obj.bookTitle)
      ..writeByte(3)
      ..write(obj.startedAt)
      ..writeByte(4)
      ..write(obj.updatedAt)
      ..writeByte(5)
      ..write(obj.chapterIndex)
      ..writeByte(6)
      ..write(obj.positionSeconds)
      ..writeByte(7)
      ..write(obj.chapterCount)
      ..writeByte(8)
      ..write(obj.chapterTitle);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ListenSessionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
