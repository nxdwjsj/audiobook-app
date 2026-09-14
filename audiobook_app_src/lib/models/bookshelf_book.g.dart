// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'bookshelf_book.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class BookshelfBookAdapter extends TypeAdapter<BookshelfBook> {
  @override
  final int typeId = 2;

  @override
  BookshelfBook read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return BookshelfBook(
      id: fields[0] as String,
      title: fields[1] as String,
      author: fields[2] as String?,
      coverUrl: fields[3] as String?,
      description: fields[4] as String?,
      chapterCount: fields[5] as int,
      isLocal: fields[6] as bool,
      localFilePath: fields[7] as String?,
      addedAt: fields[8] as DateTime?,
      driveType: fields[10] as DriveType?,
      drivePath: fields[11] as String?,
      driveDirFid: fields[14] as String?,
      isFromShare: fields[12] as bool,
      shareUrl: fields[13] as String?,
      chapters: (fields[9] as List?)?.cast<Chapter>(),
      sortOrder: fields[15] as int?,
      localCoverPath: fields[16] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, BookshelfBook obj) {
    writer
      ..writeByte(17)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.author)
      ..writeByte(3)
      ..write(obj.coverUrl)
      ..writeByte(4)
      ..write(obj.description)
      ..writeByte(5)
      ..write(obj.chapterCount)
      ..writeByte(6)
      ..write(obj.isLocal)
      ..writeByte(7)
      ..write(obj.localFilePath)
      ..writeByte(8)
      ..write(obj.addedAt)
      ..writeByte(10)
      ..write(obj.driveType)
      ..writeByte(11)
      ..write(obj.drivePath)
      ..writeByte(14)
      ..write(obj.driveDirFid)
      ..writeByte(12)
      ..write(obj.isFromShare)
      ..writeByte(13)
      ..write(obj.shareUrl)
      ..writeByte(9)
      ..write(obj.chapters)
      ..writeByte(15)
      ..write(obj.sortOrder)
      ..writeByte(16)
      ..write(obj.localCoverPath);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BookshelfBookAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
