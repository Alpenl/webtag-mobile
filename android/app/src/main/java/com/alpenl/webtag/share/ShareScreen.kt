package com.alpenl.webtag.share

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * Renders a [ShareScreenModel] and reports which row was tapped. It makes no decision of its own:
 * which labels exist, what the status line says and how many lines a label may occupy are all
 * resolved by [ShareCandidatePresenter] and covered by JVM tests.
 *
 * The parameter list is the security boundary. No submission value is passed in, so no query or
 * fragment can be drawn, and a tap can only report a position — the URL behind it is resolved by
 * [ShareCandidatePresenter.submissionValueAt], never rebuilt from the label the user saw.
 */
@Composable
internal fun ShareScreen(
    model: ShareScreenModel,
    onSelectRow: (Int) -> Unit,
    onClose: () -> Unit,
) {
    Box(modifier = Modifier.fillMaxSize().padding(20.dp), contentAlignment = Alignment.Center) {
        Surface(shadowElevation = 8.dp, tonalElevation = 4.dp, modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.share_title), style = MaterialTheme.typography.titleLarge)
                if (model.rowLabels.isNotEmpty()) {
                    Text(stringResource(R.string.share_choose_link), style = MaterialTheme.typography.bodyMedium)
                    LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        itemsIndexed(model.rowLabels) { index, label ->
                            Card(
                                modifier = Modifier.fillMaxWidth().clickable(role = Role.Button) {
                                    onSelectRow(index)
                                },
                            ) {
                                Text(
                                    label,
                                    modifier = Modifier.fillMaxWidth().padding(12.dp),
                                    maxLines = model.labelMaxLines,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    }
                } else {
                    Text(model.statusText, style = MaterialTheme.typography.bodyLarge)
                    model.selectedLabel?.let {
                        Text(
                            it,
                            maxLines = model.labelMaxLines,
                            overflow = TextOverflow.Ellipsis,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    OutlinedButton(
                        onClick = onClose,
                        enabled = model.closeEnabled,
                        modifier = Modifier.weight(1f),
                    ) {
                        Text(stringResource(R.string.close))
                    }
                }
            }
        }
    }
}
