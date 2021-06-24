USE [999998 ABC Hospital FY2016 MBD]
GO
SET NOCOUNT ON 
BEGIN TRANSACTION
BEGIN TRY 
/*-----------------------------------------------------------------------------------------*/
/*Create character map table--------------------------------------------------------------*/
DROP TABLE IF EXISTS #CharacterMap															
CREATE TABLE dbo.#CharacterMap							
(		ID						INT,			
		OriginalNumber			INT,	
		OriginalCharacter		CHAR(1),			
		NewNumber				INT,
		NewCharacter			CHAR(1))

/*-----------------------------------------------------------------------------------------*/
/*Create a list of all alphabet and digit----sort NORMAL----------------------------------*/
DROP TABLE IF EXISTS #Original
CREATE TABLE dbo.#Original	( ID			INT PRIMARY KEY IDENTITY(1,1), 
							  OriginalNumber	INT)
INSERT INTO #Original (OriginalNumber)
SELECT	number 
	FROM CDRmaster.dbo.Tally AS T
	WHERE number BETWEEN 48 AND 57
	OR number BETWEEN 65 AND 90

/*-----------------------------------------------------------------------------------------*/
/*Create a list of all alphabet and digit----sort RANDOM----------------------------------*/
DROP TABLE IF EXISTS #New
CREATE TABLE dbo.#New	( ID			INT PRIMARY KEY IDENTITY(1,1),			
						  NewNumber		INT)	
INSERT INTO #New (NewNumber)
SELECT	number 
	FROM CDRmaster.dbo.Tally AS T
	WHERE number BETWEEN 48 AND 57
	OR number BETWEEN 65 AND 90
	ORDER BY NEWID()

/*-----------------------------------------------------------------------------------------*/
/*Populate #CharacterMap table -----------------------------------------------------------*/
INSERT INTO #CharacterMap(    ID,
							  OriginalNumber,
							  OriginalCharacter,
							  NewNumber,
							  NewCharacter)
		SELECT O.ID,
				O.OriginalNumber,
				CHAR(O.OriginalNumber) AS OriginalCharacter,
				N.NewNumber,
				CHAR(N.NewNumber) AS NewCharacter
			FROM #Original AS O
			JOIN #New AS N
			ON N.ID = O.ID

/*-----------------------------------------------------------------------------------------*/
/*Create a list of tables which contain Account_Number------------------------------------*/
DROP TABLE IF EXISTS #SRtable															
CREATE TABLE dbo.#SRtable	(   ID INT IDENTITY(1,1),
								TableName	VARCHAR(255),	
								ColumnName	VARCHAR(255),
								LogicStep	INT)
INSERT INTO #SRtable(TableName,ColumnName,LogicStep)
SELECT '['+S.name+'].['+T.name+']',
		C.name,
		'1',
		'SELECT '+C.name+' FROM ['+S.name+'].['+T.name+']'
	FROM sys.columns AS C	
	JOIN sys.tables AS T
		ON T.object_id = C.object_id
	JOIN sys.schemas AS S
		ON S.schema_id = T.schema_id
	WHERE (c.name LIKE '%Account_Number%'
		OR C.name LIKE '%AccountNumber%'
		OR(C.name LIKE '%Account%' 
			AND C.name NOT LIKE '%AccountBal%' 
			AND (	T.name LIKE 'Medicare_Eligibility_%' 
					OR T.name LIKE 'Medicare_Claim_%' 
					OR T.name LIKE 'Collection_Agency_File_Summary%'))
		OR(C.name LIKE '%Mom_Account_No%' AND T.Name IN ('Prior_DSH_Log'))
			)
		AND c.name NOT LIKE '%Account_Number_Length%'
			

/*-----------------------------------------------------------------------------------------*/
/*Create Staging character map table------------------------------------------------------*/
DROP TABLE IF EXISTS #StagingTable
CREATE TABLE #StagingTable (TableName			VARCHAR(255),	ColumnName			VARCHAR(255),
							OrgAccountNumber	VARCHAR(255),	NewAccountNumber	VARCHAR(255),
							OrgChar1			CHAR(1),		NewChar1			CHAR(1))

/*-----------------------------------------------------------------------------------------*/
/*Populate initial data into #Staging table-----------------------------------------------*/
DECLARE @SQLCommand		NVARCHAR(MAX),
		@SQLCommand1	NVARCHAR(MAX),
		@SQLCommand2	NVARCHAR(MAX),
		@DbCount		INT,
		@ApplyCharMap	NVARCHAR(MAX),
		@Table			NVARCHAR(MAX),
		@Column			NVARCHAR(MAX)
SET @DbCount = (SELECT MAX(ID) FROM #SRtable AS SR WHERE SR.LogicStep = 1)
SET @SQLCommand1 = 'CONCAT( NewChar1,'
WHILE @DbCount > 0
BEGIN
	SET @Table = (SELECT SR.TableName FROM #SRtable AS SR WHERE ID = @DbCount)
	SET @Column = (SELECT SR.ColumnName FROM #SRtable AS SR WHERE ID = @DbCount)
	SET @SQLCOmmand = '
	INSERT INTO #StagingTable(  TableName,
								ColumnName,
								OrgAccountNumber,
								OrgChar1,
								NewChar1)
	SELECT	
			'''+@Table+''',
			'''+@Column+''',
			SR.'+@Column+',
			CM.OriginalCharacter,
			CM.NewCharacter
		FROM '+@Table+' AS SR
		JOIN #CharacterMap AS CM
			ON IIF (LEN(SR.'+@Column+') >= 1, SUBSTRING(SR.'+@Column+',1,1), '''') = CM.OriginalCharacter
		GROUP BY SR.'+@Column+',CM.OriginalCharacter,CM.NewCharacter
	'
	EXECUTE sys.sp_executesql @SQLCommand

	SET @DbCount -=1
END

/*-----------------------------------------------------------------------------------------*/
/*Apply character mapping rules-----------------------------------------------------------*/
SET @DbCount = 2 
WHILE @DbCount <= (SELECT MAX(LEN(ST.OrgAccountNumber)) FROM #StagingTable AS ST) 
BEGIN 
	SET @ApplyCharMap = 'IIF (LEN(ST.OrgAccountNumber) >='+CAST(@DbCount AS VARCHAR)+', SUBSTRING(ST.OrgAccountNumber,'+CAST(@DbCount AS VARCHAR)+',1), '''')'

	SET @SQLCOmmand =
				'
				ALTER TABLE #StagingTable
				ADD OrgChar'+CAST(@DbCount AS VARCHAR)+' CHAR(1), NewChar'+CAST(@DbCount AS VARCHAR)+' CHAR(1);
				'
	EXECUTE sys.sp_executesql @SQLCOmmand
	--PRINT @SQLCOmmand

	SET @SQLCOmmand =
				'
				UPDATE ST
						SET OrgChar'+CAST(@DbCount AS VARCHAR)+' = CM.OriginalCharacter,
							NewChar'+CAST(@DbCount AS VARCHAR)+' = CM.NewCharacter
					FROM #StagingTable as ST 
					JOIN #CharacterMap AS CM
						ON '+@ApplyCharMap+' = CM.OriginalCharacter
				'
	EXECUTE sys.sp_executesql @SQLCommand
	--PRINT @SQLCommand

	IF @DbCount = (SELECT MAX(LEN(ST.OrgAccountNumber)) FROM #StagingTable AS ST)
		BEGIN 
		SET @SQLCommand = ' NewChar'+CAST(@DbCount AS VARCHAR)+')'
		SET @SQLCommand1 = 'UPDATE ST SET ST.NewAccountNumber = '+@SQLCommand1 + @SQLCommand+ 'FROM #StagingTable AS ST'
		EXECUTE sys.sp_executesql @SQLCommand1
		--PRINT @SQLCommand1
		END 
	ELSE 
		BEGIN 
		SET @SQLCommand = ' NewChar'+CAST(@DbCount AS VARCHAR)+','
		SET @SQLCommand1 = @SQLCommand1 + @SQLCommand
		END 
	SET @DbCount +=1

END 

SELECT * FROM #CharacterMap AS CM				
SELECT * FROM #StagingTable AS ST	

/*Replace existing identification number with the new de-identify identification number*/
INSERT INTO #SRtable(TableName,ColumnName,LogicStep)
SELECT DISTINCT 
		ST.TableName,
		ST.ColumnName,
		'2'
	FROM #StagingTable AS ST	

SET @DbCount = (SELECT MAX(ID) FROM #SRtable AS SR WHERE SR.LogicStep = 2)
WHILE @DbCount >= (SELECT MIN(ID) FROM #SRtable AS SR WHERE SR.LogicStep = 2)
BEGIN
	SET @Table = (SELECT SR.TableName FROM #SRtable AS SR WHERE ID = @DbCount)
	SET @Column = (SELECT SR.ColumnName FROM #SRtable AS SR WHERE ID = @DbCount)
	SET @SQLCOmmand = 'UPDATE SR'+CAST(@DbCount AS VARCHAR)+'
							SET SR'+CAST(@DbCount AS VARCHAR)+'.'+@Column+' = ST.NewAccountNumber
							FROM '+@Table+' as SR'+CAST(@DbCount AS VARCHAR)+'
							JOIN #StagingTable as ST
								ON SR'+CAST(@DbCount AS VARCHAR)+'.'+@Column+' = ST.OrgAccountNumber'
	EXECUTE sys.sp_executesql @SQLCommand
	--PRINT @SQLCommand
	SET @DbCount -=1
END

END TRY
BEGIN CATCH 
	SELECT   
        ERROR_NUMBER() AS ErrorNumber  
        ,ERROR_MESSAGE() AS ErrorMessage

	IF @@TRANCOUNT > 0
		ROLLBACK TRANSACTION;
END CATCH 

IF @@TRANCOUNT > 0
	COMMIT TRANSACTION;

GO