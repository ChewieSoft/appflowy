import 'dart:collection';
import 'package:app_flowy/plugins/grid/application/cell/cell_service/cell_service.dart';
import 'package:app_flowy/plugins/grid/application/field/field_controller.dart';
import 'package:flowy_sdk/dispatch/dispatch.dart';
import 'package:flowy_sdk/log.dart';
import 'package:flowy_sdk/protobuf/flowy-grid/protobuf.dart';
import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'row_list.dart';
part 'row_cache.freezed.dart';

typedef RowUpdateCallback = void Function();

abstract class IGridRowFieldNotifier {
  UnmodifiableListView<FieldInfo> get fields;
  void onRowFieldsChanged(VoidCallback callback);
  void onRowFieldChanged(void Function(FieldInfo) callback);
  void onRowDispose();
}

/// Cache the rows in memory
/// Insert / delete / update row
///
/// Read https://appflowy.gitbook.io/docs/essential-documentation/contribute-to-appflowy/architecture/frontend/grid for more information.

class GridRowCache {
  final String gridId;
  final List<RowPB> rows;

  /// _rows containers the current block's rows
  /// Use List to reverse the order of the GridRow.
  final RowList _rowList = RowList();

  final GridCellCache _cellCache;
  final IGridRowFieldNotifier _fieldNotifier;
  final _RowChangesetNotifier _rowChangeReasonNotifier;

  UnmodifiableListView<RowInfo> get visibleRows {
    var visibleRows = [..._rowList.rows];
    return UnmodifiableListView(visibleRows);
  }

  GridCellCache get cellCache => _cellCache;

  GridRowCache({
    required this.gridId,
    required this.rows,
    required IGridRowFieldNotifier notifier,
  })  : _cellCache = GridCellCache(gridId: gridId),
        _rowChangeReasonNotifier = _RowChangesetNotifier(),
        _fieldNotifier = notifier {
    //
    notifier.onRowFieldsChanged(() => _rowChangeReasonNotifier
        .receive(const RowsChangedReason.fieldDidChange()));
    notifier.onRowFieldChanged(
        (field) => _cellCache.removeCellWithFieldId(field.id));
  }

  void initializeRows(List<RowPB> rows) {
    for (final row in rows) {
      final rowInfo = buildGridRow(row);
      _rowList.add(rowInfo);
    }
  }

  Future<void> dispose() async {
    _fieldNotifier.onRowDispose();
    _rowChangeReasonNotifier.dispose();
    await _cellCache.dispose();
  }

  void applyRowsChanged(GridViewRowsChangesetPB changeset) {
    _deleteRows(changeset.deletedRows);
    _insertRows(changeset.insertedRows);
    _updateRows(changeset.updatedRows);
  }

  void applyRowsVisibility(GridRowsVisibilityChangesetPB changeset) {
    _hideRows(changeset.invisibleRows);
    _showRows(changeset.visibleRows);
  }

  void _deleteRows(List<String> deletedRowIds) {
    for (final rowId in deletedRowIds) {
      final deletedRow = _rowList.remove(rowId);
      if (deletedRow != null) {
        _rowChangeReasonNotifier.receive(RowsChangedReason.delete(deletedRow));
      }
    }
  }

  void _insertRows(List<InsertedRowPB> insertRows) {
    for (final insertedRow in insertRows) {
      final insertedIndex =
          _rowList.insert(insertedRow.index, buildGridRow(insertedRow.row));
      if (insertedIndex != null) {
        _rowChangeReasonNotifier
            .receive(RowsChangedReason.insert(insertedIndex));
      }
    }
  }

  void _updateRows(List<UpdatedRowPB> updatedRows) {
    if (updatedRows.isEmpty) return;
    List<RowPB> rowPBs = [];
    for (final updatedRow in updatedRows) {
      for (final fieldId in updatedRow.fieldIds) {
        final key = GridCellCacheKey(
          fieldId: fieldId,
          rowId: updatedRow.row.id,
        );
        _cellCache.remove(key);
      }
      rowPBs.add(updatedRow.row);
    }

    final updatedIndexs =
        _rowList.updateRows(rowPBs, (rowPB) => buildGridRow(rowPB));
    if (updatedIndexs.isNotEmpty) {
      _rowChangeReasonNotifier.receive(RowsChangedReason.update(updatedIndexs));
    }
  }

  void _hideRows(List<String> invisibleRows) {
    for (final rowId in invisibleRows) {
      final deletedRow = _rowList.remove(rowId);
      if (deletedRow != null) {
        _rowChangeReasonNotifier.receive(RowsChangedReason.delete(deletedRow));
      }
    }
  }

  void _showRows(List<InsertedRowPB> visibleRows) {
    for (final insertedRow in visibleRows) {
      final insertedIndex =
          _rowList.insert(insertedRow.index, buildGridRow(insertedRow.row));
      if (insertedIndex != null) {
        _rowChangeReasonNotifier
            .receive(RowsChangedReason.insert(insertedIndex));
      }
    }
  }

  void onRowsChanged(void Function(RowsChangedReason) onRowChanged) {
    _rowChangeReasonNotifier.addListener(() {
      onRowChanged(_rowChangeReasonNotifier.reason);
    });
  }

  RowUpdateCallback addListener({
    required String rowId,
    void Function(GridCellMap, RowsChangedReason)? onCellUpdated,
    bool Function()? listenWhen,
  }) {
    listenerHandler() async {
      if (listenWhen != null && listenWhen() == false) {
        return;
      }

      notifyUpdate() {
        if (onCellUpdated != null) {
          final rowInfo = _rowList.get(rowId);
          if (rowInfo != null) {
            final GridCellMap cellDataMap =
                _makeGridCells(rowId, rowInfo.rowPB);
            onCellUpdated(cellDataMap, _rowChangeReasonNotifier.reason);
          }
        }
      }

      _rowChangeReasonNotifier.reason.whenOrNull(
        update: (indexs) {
          if (indexs[rowId] != null) notifyUpdate();
        },
        fieldDidChange: () => notifyUpdate(),
      );
    }

    _rowChangeReasonNotifier.addListener(listenerHandler);
    return listenerHandler;
  }

  void removeRowListener(VoidCallback callback) {
    _rowChangeReasonNotifier.removeListener(callback);
  }

  GridCellMap loadGridCells(String rowId) {
    final RowPB? data = _rowList.get(rowId)?.rowPB;
    if (data == null) {
      _loadRow(rowId);
    }
    return _makeGridCells(rowId, data);
  }

  Future<void> _loadRow(String rowId) async {
    final payload = RowIdPB.create()
      ..gridId = gridId
      ..rowId = rowId;

    final result = await GridEventGetRow(payload).send();
    result.fold(
      (optionRow) => _refreshRow(optionRow),
      (err) => Log.error(err),
    );
  }

  GridCellMap _makeGridCells(String rowId, RowPB? row) {
    // ignore: prefer_collection_literals
    var cellDataMap = GridCellMap();
    for (final field in _fieldNotifier.fields) {
      if (field.visibility) {
        cellDataMap[field.id] = GridCellIdentifier(
          rowId: rowId,
          gridId: gridId,
          fieldInfo: field,
        );
      }
    }
    return cellDataMap;
  }

  void _refreshRow(OptionalRowPB optionRow) {
    if (!optionRow.hasRow()) {
      return;
    }
    final updatedRow = optionRow.row;
    updatedRow.freeze();

    final rowInfo = _rowList.get(updatedRow.id);
    final rowIndex = _rowList.indexOfRow(updatedRow.id);
    if (rowInfo != null && rowIndex != null) {
      final updatedRowInfo = rowInfo.copyWith(rowPB: updatedRow);
      _rowList.remove(updatedRow.id);
      _rowList.insert(rowIndex, updatedRowInfo);

      final UpdatedIndexMap updatedIndexs = UpdatedIndexMap();
      updatedIndexs[rowInfo.rowPB.id] = UpdatedIndex(
        index: rowIndex,
        rowId: updatedRowInfo.rowPB.id,
      );

      _rowChangeReasonNotifier.receive(RowsChangedReason.update(updatedIndexs));
    }
  }

  RowInfo buildGridRow(RowPB rowPB) {
    return RowInfo(
      gridId: gridId,
      fields: _fieldNotifier.fields,
      rowPB: rowPB,
    );
  }
}

class _RowChangesetNotifier extends ChangeNotifier {
  RowsChangedReason reason = const InitialListState();

  _RowChangesetNotifier();

  void receive(RowsChangedReason newReason) {
    reason = newReason;
    reason.map(
      insert: (_) => notifyListeners(),
      delete: (_) => notifyListeners(),
      update: (_) => notifyListeners(),
      fieldDidChange: (_) => notifyListeners(),
      initial: (_) {},
    );
  }
}

@unfreezed
class RowInfo with _$RowInfo {
  factory RowInfo({
    required String gridId,
    required UnmodifiableListView<FieldInfo> fields,
    required RowPB rowPB,
  }) = _RowInfo;
}

typedef InsertedIndexs = List<InsertedIndex>;
typedef DeletedIndexs = List<DeletedIndex>;
// key: id of the row
// value: UpdatedIndex
typedef UpdatedIndexMap = LinkedHashMap<String, UpdatedIndex>;

@freezed
class RowsChangedReason with _$RowsChangedReason {
  const factory RowsChangedReason.insert(InsertedIndex item) = _Insert;
  const factory RowsChangedReason.delete(DeletedIndex item) = _Delete;
  const factory RowsChangedReason.update(UpdatedIndexMap indexs) = _Update;
  const factory RowsChangedReason.fieldDidChange() = _FieldDidChange;
  const factory RowsChangedReason.initial() = InitialListState;
}

class InsertedIndex {
  final int index;
  final String rowId;
  InsertedIndex({
    required this.index,
    required this.rowId,
  });
}

class DeletedIndex {
  final int index;
  final RowInfo rowInfo;
  DeletedIndex({
    required this.index,
    required this.rowInfo,
  });
}

class UpdatedIndex {
  final int index;
  final String rowId;
  UpdatedIndex({
    required this.index,
    required this.rowId,
  });
}
