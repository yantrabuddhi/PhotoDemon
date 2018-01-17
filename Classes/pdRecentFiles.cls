VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
  Persistable = 0  'NotPersistable
  DataBindingBehavior = 0  'vbNone
  DataSourceBehavior  = 0  'vbNone
  MTSTransactionMode  = 0  'NotAnMTSObject
END
Attribute VB_Name = "pdRecentFiles"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'***************************************************************************
'File > Open Recent List Manager
'Copyright 2005-2018 by Raj Chaudhuri and Tanner Helland
'Created: 16/February/15
'Last updated: 11/September/17
'Last update: Rewrote class from scratch as a standalone instance, to enable optimizations that aren't easily
'             accomplished otherwise (especially regarding maintenance of image thumbnails).
'
'PhotoDemon's File > Open Recent menu supports some neat features, like large thumbnail icons on Vista+.  This class
' is responsible for maintaining the full list of file paths and thumbnails for that menu.
'
'Many thanks to Raj Chaudhuri for his original work on this class.  I feel bad that I had to rewrite the whole thing
' in 2017, but this class was consuming an inordinately large amount of time (especially because it was only storing
' thumbnails in file, not in memory - so every menu refresh required a full trip out to the HDD, and manually loading
' every thumbnail in the menu!) so it really needed to be dealt with before 7.0 releases.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************
Option Explicit


'The user actually controls the number of entries in the list, but we initialize it to PD's default size to avoid the
' need for new allocations until the list hits a certain size.
Private Const DEFAULT_LIST_COUNT As Long = 10&

'Recent file captions need to fit inside menus; their length must thus be restricted (and for convenience, we use chars
' instead of pixels).
Private Const MAX_CAPTION_LENGTH_CHARS As Long = 64

'Recent files must track more than just paths; we also track thumbnails, hashed filenames (used for storing thumbnails),
' and possibly additional features in the future.  To reduce the amount of time spent processing these objects, we store
' everything in a dedicated table.
Private Type MRUEntry
    fullPathAndFilename As String
    hashedFilename As String
    fullThumbPathAndFilename As String
    imgThumbnail As pdDIB
    hasChangedThisSession As Boolean
End Type

'MRUlist will contain string entries of all the most recently used files
Private m_Items() As MRUEntry

'Current number of entries in the MRU list.  Note that this is constrained by a global user preference.
Private m_ItemCount As Long

'PD's standard XML engine is used to read/write the recent file lists persistently.  (Lists are only copied out
' to file when the program closes; during a given session, everything is managed in-memory for performance reasons.)
Private m_XMLEngine As pdXML

'The file where this class persistently stores its data.  In PD, the path of this file is controlled by the global
' preferences object (g_UserPreferences).
Private m_XMLFilename As String

'Recent file entries have matching thumbnails; thumbnail paths are generated by hashing
Private m_Hasher As pdCrypto

'When creating a new MRU file, use this to initialize a standard XML header.
Private Sub ResetXMLData()
    m_XMLEngine.PrepareNewXML "Recent files"
    m_XMLEngine.WriteBlankLine
    m_XMLEngine.WriteComment "Everything past this point is recent file data.  Entries are sorted in reverse chronological order."
    m_XMLEngine.WriteBlankLine
End Sub

'Return the menu caption of the current recent file entry.  At present, menu caption length is controlled by a global preference
Friend Function GetMenuCaption(ByVal itemIndex As Long) As String
    
    If (itemIndex >= 0) And (itemIndex < m_ItemCount) Then
    
        'Based on the user's preference, display just the filename or the entire file path (up to the max character length)
        If (g_UserPreferences.GetPref_Long("Core", "MRU Caption Length", 0) = 0) Then
            GetMenuCaption = Files.FileGetName(m_Items(itemIndex).fullPathAndFilename)
        Else
            GetMenuCaption = Files.PathCompact(m_Items(itemIndex).fullPathAndFilename, MAX_CAPTION_LENGTH_CHARS)
        End If
    
    Else
        InternalError "GetMenuCaption: itemIndex OOB"
    End If
    
End Function

'Return the actual file path at a given index
Friend Function GetFullPath(ByVal itemIndex As Long) As String
    
    If (itemIndex >= 0) And (itemIndex < m_ItemCount) Then
        GetFullPath = m_Items(itemIndex).fullPathAndFilename
    Else
        InternalError "GetFullPath: itemIndex OOB"
    End If
    
End Function

'Return an actual thumbnail as a pdDIB object
Friend Function GetMRUThumbnail(ByVal itemIndex As Long) As pdDIB
    
    If (itemIndex >= 0) And (itemIndex < m_ItemCount) Then
        Set GetMRUThumbnail = m_Items(itemIndex).imgThumbnail
    Else
        InternalError "GetMRUThumbnail: itemIndex OOB"
    End If
    
End Function

'Load the entire recent file list from a previously saved XML file.  Note that this erases the *full contents*
' of the current list!
Friend Sub LoadListFromFile()

    'Start by seeing if an XML file with previously saved MRU data exists
    If Files.FileExists(m_XMLFilename) Then
        
        'Attempt to load and validate the current file; if we can't, create a new, blank XML object
        If (Not m_XMLEngine.LoadXMLFile(m_XMLFilename)) Then
            InternalError "LoadListFromFile: XML data at " & m_XMLFilename & " didn't validate."
            ResetXMLData
        End If
        
    Else
        ResetXMLData
    End If
    
    'The XML engine does the heavy lifting for this task.  We pass it a String array, and it fills it with
    ' all values corresponding to the given tag name and attribute.  (We must do this dynamically, because we don't
    ' know how many recent filenames are actually saved - it could be anywhere from 0 to RECENT_FILE_COUNT.)
    Dim allRecentFiles() As String
    If m_XMLEngine.FindAllAttributeValues(allRecentFiles, "mruEntry", "id") Then
        
        m_ItemCount = UBound(allRecentFiles) + 1
        
        'Make sure the file does not contain more entries than are allowed (shouldn't theoretically be possible,
        ' but it doesn't hurt to check).
        If (m_ItemCount > g_UserPreferences.GetPref_Long("Interface", "Recent Files Limit", 10)) Then
            m_ItemCount = g_UserPreferences.GetPref_Long("Interface", "Recent Files Limit", 10)
        End If
        
    'No recent file entries were found.  Adjust the Recent Files menu to match
    Else
        m_ItemCount = 0
        UpdateUI_EmptyList
    End If
    
    'If one or more recent file entries were found, load them now.
    If (m_ItemCount > 0) Then
        
        'Prepare our internal file list
        ReDim m_Items(0 To m_ItemCount - 1) As MRUEntry
        
        'Load the actual file paths from the MRU file
        Dim i As Long
        For i = 0 To m_ItemCount - 1
        
            'Filename is the only item actually stored in the XML file
            m_Items(i).fullPathAndFilename = m_XMLEngine.GetUniqueTag_String("filePath", , , "mruEntry", "id", allRecentFiles(i))
            
            'From the filename, generate a matching hash.  (This is required for determining the thumbnail path.)
            m_Items(i).hashedFilename = GetHashedFilename(m_Items(i).fullPathAndFilename)
            
            'Load the file, if any, into a usable DIB
            m_Items(i).fullThumbPathAndFilename = g_UserPreferences.GetIconPath & m_Items(i).hashedFilename & ".pdtmp"
            If Files.FileExists(m_Items(i).fullThumbPathAndFilename) Then
                Set m_Items(i).imgThumbnail = New pdDIB
                m_Items(i).imgThumbnail.CreateFromFile m_Items(i).fullThumbPathAndFilename
            Else
                Set m_Items(i).imgThumbnail = Nothing
            End If
            
        Next i
        
        UpdateUI_NonEmptyList
        
    End If
    
End Sub

'Update the UI against a non-empty list
Friend Sub UpdateUI_NonEmptyList()
    
    If (m_ItemCount > 0) Then
        
        Dim i As Long
        
        'First, make sure we have the correct number of menus available
        If (m_ItemCount <> FormMain.mnuRecDocs.Count) Then
        
            'Check for too many menus...
            If (FormMain.mnuRecDocs.Count > m_ItemCount) Then
                For i = m_ItemCount To FormMain.mnuRecDocs.Count - 1
                    Unload FormMain.mnuRecDocs(i)
                Next i
            
            'Check for too few menus...
            Else
                For i = FormMain.mnuRecDocs.Count To m_ItemCount - 1
                    Load FormMain.mnuRecDocs(i)
                Next i
            End If
        
        End If
        
        'Now that we have the correct number of controls, make sure all menus are enabled.
        For i = 0 To FormMain.mnuRecDocs.Count - 1
            FormMain.mnuRecDocs(i).Enabled = True
        Next i
        
        'If (for some reason) there is a mismatch between our current menu count and the existing menu count,
        ' kill any extra menus.
        If (FormMain.mnuRecDocs.Count > m_ItemCount) Then
            For i = m_ItemCount To FormMain.mnuRecDocs.Count - 1
                Unload FormMain.mnuRecDocs(i)
            Next i
        End If
        
        'Ensure the special menus at the bottom of the Recent Files list are available
        FormMain.MnuRecentSepBar1.Visible = True
        FormMain.MnuLoadAllMRU.Visible = True
        FormMain.MnuClearMRU.Visible = True
        
        'Update any relevant thumbnail icons.  (TODO: ensure this isn't being called from multiple places.)
        IconsAndCursors.ResetMenuIcons
        
    Else
        UpdateUI_EmptyList
    End If
    
End Sub

'Update the UI against an empty list; this involves unloading all existing recent file menu entries (if any)
Friend Sub UpdateUI_EmptyList()
    
    If (m_ItemCount = 0) Then
    
        Dim i As Long
        If FormMain.mnuRecDocs.Count > 1 Then
            For i = 1 To FormMain.mnuRecDocs.Count - 1
                Unload FormMain.mnuRecDocs(i)
            Next i
        End If
        
        FormMain.mnuRecDocs(0).Enabled = False
        FormMain.MnuRecentSepBar1.Visible = False
        FormMain.MnuClearMRU.Visible = False
        FormMain.MnuLoadAllMRU.Visible = False
        
        'All icons in this menu need to be manually reset after the list is cleared; the ResetMenuIcons function
        ' will also call the Menus.UpdateSpecialMenu_RecentFiles() function to set all captions properly.
        IconsAndCursors.ResetMenuIcons
        
    Else
        UpdateUI_NonEmptyList
    End If
    
End Sub

'Return a 16-character hash of a specific MRU entry.  (This is used to generate unique menu icon filenames.)
Private Function GetHashedFilename(ByRef srcFullPath As String) As String
    GetHashedFilename = m_Hasher.QuickHashString(srcFullPath)
End Function

'Save the current MRU list to file (currently done at program close)
Friend Sub WriteListToFile()
    
    'Reset whatever XML data we may have stored at present - we will be rewriting the full MRU file from scratch.
    ResetXMLData
    
    'Only write new entries if MRU data exists for them
    If (m_ItemCount > 0) Then
    
        Dim i As Long
        For i = 0 To m_ItemCount - 1
            m_XMLEngine.WriteTagWithAttribute "mruEntry", "id", CStr(i), vbNullString, True
            m_XMLEngine.WriteTag "filePath", m_Items(i).fullPathAndFilename
            m_XMLEngine.CloseTag "mruEntry"
            m_XMLEngine.WriteBlankLine
        Next i
        
    End If
    
    'With the XML file now complete, write it out to file
    m_XMLEngine.WriteXMLToFile m_XMLFilename
    
    'Save all file thumbnails, and in the process, remove any orphaned thumbnail files
    WriteAllThumbnails
    
    Exit Sub
    
MRUSaveFailure:
    InternalError "WriteListToFile encountered error #" & Err.Number & ", " & Err.Description
    
End Sub

Private Function GetIndexFromThumbPath(ByRef srcThumbPath As String) As Long
    
    GetIndexFromThumbPath = -1
    
    Dim i As Long
    For i = 0 To m_ItemCount - 1
        If Strings.StringsEqual(srcThumbPath, m_Items(i).fullThumbPathAndFilename, True) Then
            GetIndexFromThumbPath = i
            Exit For
        End If
    Next i
    
End Function

Private Sub WriteAllThumbnails()

    'Before writing out our files, look for any orphaned thumbnails that are no longer required
    Dim thumbFileList As pdStringStack
    
    If Files.RetrieveAllFiles(g_UserPreferences.GetIconPath, thumbFileList, False, False, "pdtmp") Then
    
        Dim chkFile As String, chkFileIndex As Long
        
        'Enumerate all thumbnails that currently exist in the folder, and kill 'em if they...
        ' 1) Don't exist in our current list
        ' 2) Exist in our current list, but that image has changed during this session.  (We're gonna write a
        '    new thumbnail, so this one is no longer needed.)
        Do While thumbFileList.PopString(chkFile)
            
            chkFileIndex = GetIndexFromThumbPath(chkFile)
            If (chkFileIndex >= 0) Then
                If m_Items(chkFileIndex).hasChangedThisSession Then Files.FileDelete chkFile
            Else
                Files.FileDelete chkFile
            End If
            
        Loop
    
    End If
    
    'Now, write out all of our internally cached thumbnails
    Dim i As Long
    For i = 0 To m_ItemCount - 1
        If (Not m_Items(i).imgThumbnail Is Nothing) And (Len(m_Items(i).fullThumbPathAndFilename) <> 0) Then
            If m_Items(i).hasChangedThisSession Then m_Items(i).imgThumbnail.WriteToFile m_Items(i).fullThumbPathAndFilename, PD_CE_Lz4
        End If
    Next i
    
End Sub

'Add another file to the MRU list.  Optionally, the associated thumbnail can also be updated.  If the passed source image is non-null,
' the thumbnail will be updated automatically.
Friend Sub AddFileToList(ByRef srcFile As String, Optional ByRef srcImage As pdImage = Nothing)
    
    'The filename is sometimes passed directly from system dialogs, which means it may contain nulls.
    ' (NOTE: because PD now uses its own custom-built wrappers, this is no longer a concern, but I've left it in case
    '  others want to adopt this module in their own projects.)
    srcFile = Strings.TrimNull(srcFile)
    
    'Next, see if this file already exists in our collection.  If it does, we will simply shuffle its position
    ' instead of adding it as a new entry.
    Dim curLocation As Long
    curLocation = -1
    
    Dim i As Long
    For i = 0 To m_ItemCount - 1
    
        'This file already exists in the list!  Make a note of its location, then exit.
        If Strings.StringsEqual(m_Items(i).fullPathAndFilename, srcFile, True) Then
            curLocation = i
            Exit For
        End If
        
    Next i
    
    If (curLocation >= 0) Then
    
        'This file already exists in our list.  Shift it into its correct position.  (Note that we don't need to do
        ' this if the entry is already at position 0.)
        If (curLocation > 0) And (m_ItemCount > 1) Then
            For i = curLocation To 1 Step -1
                m_Items(i) = m_Items(i - 1)
            Next i
        End If
    
    'This file doesn't exist in the MRU list, so it must be added at the very top as a new entry.  Other items will
    ' potentially be pushed off the end of the list.
    Else
        
        m_ItemCount = m_ItemCount + 1
        
        'Cap the number of MRU files at a certain value (specified by the user in the Preferences menu)
        If (m_ItemCount > g_UserPreferences.GetPref_Long("Interface", "Recent Files Limit", DEFAULT_LIST_COUNT)) Then m_ItemCount = g_UserPreferences.GetPref_Long("Interface", "Recent Files Limit", DEFAULT_LIST_COUNT)
        
        'Resize the list of MRU entries, which may have grown on account of this new addition.
        If (m_ItemCount > UBound(m_Items)) Then ReDim Preserve m_Items(0 To m_ItemCount - 1) As MRUEntry
    
        'Shift all existing entries downward
        If (m_ItemCount > 1) Then
            For i = m_ItemCount - 1 To 1 Step -1
                m_Items(i) = m_Items(i - 1)
            Next i
        End If
        
    End If
    
    'Add this entry to the top of the list
    With m_Items(0)
    
        .fullPathAndFilename = srcFile
        
        'While we're here, hash the filename and generate a full thumbnail path as well
        .hashedFilename = GetHashedFilename(srcFile)
        .fullThumbPathAndFilename = g_UserPreferences.GetIconPath & .hashedFilename & ".pdtmp"
        
        'Request a thumbnail
        Set .imgThumbnail = New pdDIB
        srcImage.RequestThumbnail .imgThumbnail, IIf(OS.IsVistaOrLater, 64, 16)
        
        'Note that the image *has* changed this session; this guarantees we will write its thumbnail out to file
        ' when the program closes
        .hasChangedThisSession = True
        
    End With
    
    'Apply any necessary UI changes
    UpdateUI_NonEmptyList
    
End Sub

'If the user changes their preference regarding the number of recent files we can save, call this sub to rebuild
' the current menu.
Friend Sub NotifyMaxLimitChanged()
    
    'Erase any entries above the new limit
    If (m_ItemCount > g_UserPreferences.GetPref_Long("Interface", "Recent Files Limit", DEFAULT_LIST_COUNT)) Then
        
        m_ItemCount = g_UserPreferences.GetPref_Long("Interface", "Recent Files Limit", DEFAULT_LIST_COUNT)
        
        'Resize our array as necessary; this will also dump resources (like thumbnail DIBs) that are no longer required
        ReDim Preserve m_Items(0 To m_ItemCount - 1) As MRUEntry
        
        'Update the UI to reflect the smaller list
        UpdateUI_NonEmptyList
        
    End If
    
    'Write the current MRU list out to file.
    WriteListToFile
    
End Sub

'Empty the entire MRU list and clear the menu of all entries
Friend Sub ClearList()
    
    'Reset the number of entries in the MRU list
    m_ItemCount = 0
    
    'Immediately erase the saved XML data and write it to file
    WriteListToFile
    
    'Update the UI to reflect the new list
    UpdateUI_EmptyList
    
End Sub

'Return the number of MRU entries currently loaded and active
Friend Function GetNumOfItems() As Long
    GetNumOfItems = m_ItemCount
End Function

Private Sub InternalError(ByVal errText As String)
    #If DEBUGMODE = 1 Then
        pdDebug.LogAction "WARNING!  pdRecentFiles has a problem: " & errText
    #End If
End Sub

Private Sub Class_Initialize()

    'Initialize an XML engine, which we use to read/write MRU data to file
    Set m_XMLEngine = New pdXML
    m_XMLEngine.SetTextCompareMode vbBinaryCompare
    
    'The location of our saved file is hard-coded at initialization time
    m_XMLFilename = g_UserPreferences.GetPresetPath & "Program_RecentFiles.xml"
    
    'Prep a fast hasher
    Set m_Hasher = New pdCrypto
    
    'Avoid the need to check for an initialized list
    ReDim m_Items(0 To DEFAULT_LIST_COUNT - 1) As MRUEntry
    
End Sub

Private Sub Class_Terminate()
    
    'No special clean-up is required at shutdown time.  Just make sure to write this list out to file before killing it!
    
End Sub